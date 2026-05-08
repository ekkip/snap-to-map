import CoreGraphics
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
		print("\(#function) – \(d.width) × \(d.height) = \(d.width * d.height)")
        return d.width * d.height
    }

    var rasterExceedsLargeOverlayPixelThreshold: Bool {
        rasterPixelCount() > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive
    }
}

/// Georeferenced image via `MKOverlay` / `MKOverlayRenderer`. Heavy sources use **`OverlayMapPresentation`** → **`BakedImageMapTileOverlay`** (see **`sourceImage.rasterExceedsLargeOverlayPixelThreshold`**).
final class ImageRasterMapOverlay: NSObject, MKOverlay {
    let overlayID: UUID
    let image: UIImage

    /// `true` when the source bitmap spans more than **100 megapixels** (see `UIImage.rasterExceedsLargeOverlayPixelThreshold`).
    let largeImage: Bool

    private let mapBoundingRect: MKMapRect
    weak var opacityBag: RasterMapOpacityBag?

    init(
        overlayID: UUID,
        image: UIImage,
        mapBoundingRect: MKMapRect,
        largeImage: Bool,
        opacityBag: RasterMapOpacityBag
    ) {
        self.overlayID = overlayID
        self.image = image
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
        let bbox = overlay.boundingMapRect
        let clipped = bbox.intersection(mapRect)
        guard !clipped.isNull, !clipped.isEmpty, clipped.size.width > 0, clipped.size.height > 0 else { return }
        guard let cgImage = Self.normalizedCGImage(from: overlay.image) else { return }

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
