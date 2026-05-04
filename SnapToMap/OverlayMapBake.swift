import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import MapKit
import UIKit

/// One-time “bake” of **`source`** + geographic quad into a **Mercator axis-aligned** texture keyed to **`boundingMapRect`**, so **`MKMapView`** browse mode only stretches a rectangle (no per-frame projective work).
enum OverlayMapBake {
    /// Longest output side; keeps memory bounded (~16 MP at 4096).
    private static let defaultMaxOutputDimension: Int = 4096
    /// Downsample source before **`CIPerspectiveTransform`** so multi‑hundred‑MP inputs do not peak device RAM.
    private static let maxSourceDimensionForCI: CGFloat = 8192

    static func mapBoundingMapRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        let points = coordinates.map { MKMapPoint($0) }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return MKMapRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 1),
            height: max(maxY - minY, 1)
        )
    }

    /// Builds the map browse texture; **`nil`** only if geometry/CG conversion fails.
    static func bakeMercatorDisplayTexture(
        source: UIImage,
        corners: [CLLocationCoordinate2D],
        maxOutputDimension: Int = defaultMaxOutputDimension
    ) -> UIImage? {
        guard corners.count == 4, let cgIn = normalizedCGImage(from: source) else { return nil }
        let bbox = mapBoundingMapRect(for: corners)
        let ox = bbox.origin.x
        let oy = bbox.origin.y
        let bw = bbox.size.width
        let bh = bbox.size.height
        guard bw.isFinite, bh.isFinite, bw > 0, bh > 0 else { return nil }

        let aspect = bw / bh
        let W: Int
        let H: Int
        if aspect >= 1 {
            W = maxOutputDimension
            H = max(1, Int((Double(maxOutputDimension) / Double(aspect)).rounded(.toNearestOrAwayFromZero)))
        } else {
            H = maxOutputDimension
            W = max(1, Int((Double(maxOutputDimension) * Double(aspect)).rounded(.toNearestOrAwayFromZero)))
        }

        var ci = CIImage(cgImage: cgIn)
        ci = downscaleCIIfNeeded(ci, maxDimension: maxSourceDimensionForCI)

        let mapPts = corners.map { MKMapPoint($0) }
        let ciH = CGFloat(H)

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = ci
        for i in 0..<4 {
            let mp = mapPts[i]
            let px = (mp.x - ox) / bw * CGFloat(W)
            let pyFromNorth = (mp.y - oy) / bh * CGFloat(H)
            let ciPt = CGPoint(x: px, y: ciH - pyFromNorth)
            switch i {
            case 0: filter.topLeft = ciPt
            case 1: filter.topRight = ciPt
            case 2: filter.bottomRight = ciPt
            case 3: filter.bottomLeft = ciPt
            default: break
            }
        }

        guard let output = filter.outputImage else { return nil }

        let targetExtent = CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))
        let cropped = output.cropped(to: targetExtent)
        let clearBackdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: targetExtent)
        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = cropped
        composite.backgroundImage = clearBackdrop
        guard let composited = composite.outputImage?.cropped(to: targetExtent) else { return nil }

        let rectToRender = composited.extent.integral
        guard rectToRender.width >= 2, rectToRender.height >= 2 else { return nil }

        let ctx = CIContext(options: [.highQualityDownsample: true])
        guard let cgOut = ctx.createCGImage(composited, from: rectToRender) else { return nil }
        return UIImage(cgImage: cgOut, scale: 1, orientation: .up)
    }

    private static func downscaleCIIfNeeded(_ input: CIImage, maxDimension: CGFloat) -> CIImage {
        let e = input.extent
        let w = e.width
        let h = e.height
        let m = max(w, h)
        guard m > maxDimension, m > 0 else { return input }
        let s = maxDimension / m
        let scaled = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y))
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return drawn.cgImage
    }
}
