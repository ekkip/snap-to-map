import CoreGraphics
import CoreLocation
import MapKit
import UIKit

extension UIImage {
    /// Raster pixel dimensions (backing bitmap, excluding orientation quirks when `cgImage` is present).
    private func rasterPixelDimensions() -> (width: Int64, height: Int64) {
        if let cg = cgImage {
            return (Int64(cg.width), Int64(cg.height))
        }
        let w = Int64(round(size.width * scale))
        let h = Int64(round(size.height * scale))
        return (w, h)
    }

    /// Total pixel count of the raster.
    func rasterPixelCount() -> Int64 {
        let d = rasterPixelDimensions()
        return d.width * d.height
    }

    /// True when **`width × height` > 100_000_000** (more than ~100 MP); used like a heavyweight **`MKTileOverlay`** stack for opacity repaint.
    static let largeRasterOverlayPixelThresholdExclusive: Int64 = 100_000_000

    var rasterExceedsLargeOverlayPixelThreshold: Bool {
        rasterPixelCount() > Self.largeRasterOverlayPixelThresholdExclusive
    }
}

/// Georeferenced image via `MKOverlay` / `MKOverlayRenderer` (similar consumer cost profile to tiled `MKTileOverlay` overlays).
final class ImageRasterMapOverlay: NSObject, MKOverlay {
    let overlayID: UUID
    let image: UIImage

    /// `true` when the source bitmap spans more than **100 megapixels** (see `UIImage.rasterExceedsLargeOverlayPixelThreshold`).
    let largeImage: Bool

    /// Screen placement order when saved: **top-left → top-right → bottom-right → bottom-left** (matches **`ContentView`** draft quad).
    let cornerCoordinates: [CLLocationCoordinate2D]

    private let mapBoundingRect: MKMapRect
    weak var opacityBag: RasterMapOpacityBag?

    init(
        overlayID: UUID,
        image: UIImage,
        cornerCoordinates: [CLLocationCoordinate2D],
        mapBoundingRect: MKMapRect,
        largeImage: Bool,
        opacityBag: RasterMapOpacityBag
    ) {
        self.overlayID = overlayID
        self.image = image
        self.cornerCoordinates = cornerCoordinates
        self.largeImage = largeImage
        self.mapBoundingRect = mapBoundingRect
        self.opacityBag = opacityBag
        super.init()
    }

    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: mapBoundingRect.midX, y: mapBoundingRect.midY).coordinate
    }

    var boundingMapRect: MKMapRect { mapBoundingRect }
}

final class ImageRasterMapOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let overlay = overlay as? ImageRasterMapOverlay else { return }
        guard let cgImage = Self.normalizedCGImage(from: overlay.image) else { return }

        let geo = overlay.cornerCoordinates
        if geo.count == 4 {
            let mapPts = geo.map { MKMapPoint($0) }
            guard mapPts.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
            let cornerClip = quadBoundingMapRect(mapPts).intersection(mapRect)
            guard !cornerClip.isNull, !cornerClip.isEmpty else { return }

            let p = mapPts.map { point(for: $0) }
            guard p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }

            let iw = CGFloat(cgImage.width)
            let ih = CGFloat(cgImage.height)
            guard iw > 0, ih > 0 else { return }

            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.addRect(rect(for: cornerClip))
            ctx.clip()
            ctx.interpolationQuality = .high

            // `CGContext.draw` uses a bottom-left origin for the bitmap rect; affines map UIKit-style corners (TL, TR, BL, BR).
            let uiFromCgBitmapRect = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: ih)

            let m1 = Self.affineImageTLTRBLToPoints(
                imageWidth: iw,
                imageHeight: ih,
                topLeft: p[0],
                topRight: p[1],
                bottomLeft: p[3]
            )
            ctx.saveGState()
            ctx.concatenate(m1)
            ctx.concatenate(uiFromCgBitmapRect)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: iw, height: ih))
            ctx.restoreGState()

            let m2 = Self.affineImageTRBRBLToPoints(
                imageWidth: iw,
                imageHeight: ih,
                topRight: p[1],
                bottomRight: p[2],
                bottomLeft: p[3]
            )
            ctx.saveGState()
            ctx.concatenate(m2)
            ctx.concatenate(uiFromCgBitmapRect)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: iw, height: ih))
            ctx.restoreGState()
        } else {
            let bbox = overlay.boundingMapRect
            let clipped = bbox.intersection(mapRect)
            guard !clipped.isNull, !clipped.isEmpty, clipped.size.width > 0, clipped.size.height > 0 else { return }

            let destRect = rect(for: clipped)

            let u0 = (clipped.origin.x - bbox.origin.x) / bbox.size.width
            let u1 = (clipped.maxX - bbox.origin.x) / bbox.size.width
            let v0 = (clipped.origin.y - bbox.origin.y) / bbox.size.height
            let v1 = (clipped.maxY - bbox.origin.y) / bbox.size.height

            let iw = CGFloat(cgImage.width)
            let ih = CGFloat(cgImage.height)
            guard iw > 0, ih > 0 else { return }

            let srcRect = CGRect(
                x: u0 * iw,
                y: v0 * ih,
                width: max(u1 - u0, 0) * iw,
                height: max(v1 - v0, 0) * ih
            ).integral
            guard srcRect.width >= 1, srcRect.height >= 1 else { return }
            guard let cropped = cgImage.cropping(to: srcRect) else { return }

            ctx.saveGState()
            defer { ctx.restoreGState() }
            // Opacity is applied via **`MKOverlayRenderer.alpha`** (see **`MapViewBridge.applyRasterOverlayRendererAlphas`**) so slider changes
            // composite smoothly without re-running this heavyweight draw on every drag frame (unlike SwiftUI `.opacity` on the edit overlay).
            ctx.interpolationQuality = .high
            ctx.translateBy(x: destRect.minX, y: destRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            let localDest = CGRect(origin: .zero, size: destRect.size)
            ctx.draw(cropped, in: localDest)
        }
    }

    /// `CGAffineTransform` maps image top-left **(0,0)**, top-right **(w,0)**, bottom-left **(0,h)** (UIKit-style bitmap) onto **`pTL` / `pTR` / `pBL`** in renderer coordinates.
    private static func affineImageTLTRBLToPoints(
        imageWidth w: CGFloat,
        imageHeight h: CGFloat,
        topLeft pTL: CGPoint,
        topRight pTR: CGPoint,
        bottomLeft pBL: CGPoint
    ) -> CGAffineTransform {
        let tx = pTL.x
        let ty = pTL.y
        let a = (pTR.x - pTL.x) / w
        let b = (pTR.y - pTL.y) / w
        let c = (pBL.x - pTL.x) / h
        let d = (pBL.y - pTL.y) / h
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// Maps top-right **(w,0)**, bottom-right **(w,h)**, bottom-left **(0,h)** onto **`pTR` / `pBR` / `pBL`**.
    private static func affineImageTRBRBLToPoints(
        imageWidth w: CGFloat,
        imageHeight h: CGFloat,
        topRight pTR: CGPoint,
        bottomRight pBR: CGPoint,
        bottomLeft pBL: CGPoint
    ) -> CGAffineTransform {
        let c = (pBR.x - pTR.x) / h
        let d = (pBR.y - pTR.y) / h
        let a = (pTR.x - pBL.x + c * h) / w
        let b = (pTR.y - pBL.y + d * h) / w
        let tx = pBL.x - c * h
        let ty = pBL.y - d * h
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    private func quadBoundingMapRect(_ pts: [MKMapPoint]) -> MKMapRect {
        guard let first = pts.first else { return .null }
        var r = MKMapRect(origin: MKMapPoint(x: first.x, y: first.y), size: MKMapSize(width: 0, height: 0))
        for p in pts.dropFirst() {
            let mr = MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))
            r = r.union(mr)
        }
        return r.isEmpty ? MKMapRect(x: first.x, y: first.y, width: 1, height: 1) : r
    }

    /// Renders UIImage with `.up` orientation so sampling matches geographic top/bottom.
    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return drawn.cgImage
    }
}

final class OverlayMarkerAnnotation: NSObject, MKAnnotation {
    let overlayID: UUID
    dynamic var coordinate: CLLocationCoordinate2D

    init(overlayID: UUID, coordinate: CLLocationCoordinate2D) {
        self.overlayID = overlayID
        self.coordinate = coordinate
        super.init()
    }
}
