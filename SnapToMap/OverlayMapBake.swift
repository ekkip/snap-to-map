import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import MapKit
import UIKit

/// One-time “bake” of **`source`** + geographic quad into a **Mercator axis-aligned** texture keyed to **`boundingMapRect`**, so **`MKMapView`** browse mode only stretches a rectangle (no per-frame projective work).
enum OverlayMapBake {
    /// Default baked-output budget (~16.8 MP; equivalent to 4096²).
    private static let defaultOutputPixelBudget: CGFloat = 16_777_216
    /// Larger baked-output budget for heavy sources (~67 MP; equivalent to 8192²).
    /// Keeps browse detail high while avoiding 1+ GB transient RGBA allocations for 400 MP-class imports.
    private static let highResOutputPixelBudget: CGFloat = 67_108_864
    /// Default CI input budget before perspective warp (~67 MP; equivalent to 8192²).
    private static let defaultSourceCIPixelBudget: CGFloat = 67_108_864
    /// CI input budget for very large source rasters (~134 MP; equivalent to 11585²).
    /// This prevents full-resolution perspective filtering on extremely large camera images.
    private static let highResSourceCIPixelBudget: CGFloat = 134_217_728

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

    /// Picks bake limits from **`source`** so browse texture and tiling see enough pixels to matter.
    static func bakeMercatorDisplayTextureForBrowse(source: UIImage, corners: [CLLocationCoordinate2D]) -> UIImage? {
        if source.rasterExceedsLargeOverlayPixelThreshold {
            return bakeMercatorDisplayTexture(
                source: source,
                corners: corners,
                outputPixelBudget: highResOutputPixelBudget,
                sourceCIPixelBudget: highResSourceCIPixelBudget
            )
        }
        return bakeMercatorDisplayTexture(source: source, corners: corners)
    }

    /// Builds the map browse texture; **`nil`** only if geometry/CG conversion fails.
    static func bakeMercatorDisplayTexture(
        source: UIImage,
        corners: [CLLocationCoordinate2D],
        outputPixelBudget: CGFloat = defaultOutputPixelBudget,
        sourceCIPixelBudget: CGFloat = defaultSourceCIPixelBudget
    ) -> UIImage? {
        guard corners.count == 4, let cgIn = normalizedCGImage(from: source) else { return nil }
        let bbox = mapBoundingMapRect(for: corners)
        let ox = bbox.origin.x
        let oy = bbox.origin.y
        let bw = bbox.size.width
        let bh = bbox.size.height
        guard bw.isFinite, bh.isFinite, bw > 0, bh > 0 else { return nil }

        let aspect = bw / bh
        let (W, H) = outputSizeForAspect(aspect, pixelBudget: outputPixelBudget)

        var ci = CIImage(cgImage: cgIn)
        ci = downscaleCIIfNeeded(ci, pixelBudget: sourceCIPixelBudget)

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
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let cgOut = ctx.createCGImage(composited, from: rectToRender, format: .RGBA8, colorSpace: colorSpace) {
            return UIImage(cgImage: cgOut, scale: 1, orientation: .up)
        }
        guard let cgFallback = ctx.createCGImage(composited, from: rectToRender) else { return nil }
        return UIImage(cgImage: cgFallback, scale: 1, orientation: .up)
    }

    private static func outputSizeForAspect(_ aspect: Double, pixelBudget: CGFloat) -> (Int, Int) {
        let safeAspect = max(CGFloat(1e-6), CGFloat(aspect.isFinite ? aspect : 1))
        let budget = max(1, pixelBudget)
        let w = sqrt(budget * safeAspect)
        let h = sqrt(budget / safeAspect)
        return (max(1, Int(w.rounded(.toNearestOrAwayFromZero))),
                max(1, Int(h.rounded(.toNearestOrAwayFromZero))))
    }

    private static func downscaleCIIfNeeded(_ input: CIImage, pixelBudget: CGFloat) -> CIImage {
        let e = input.extent
        let w = e.width
        let h = e.height
        guard w > 0, h > 0 else { return input }
        let pixels = w * h
        let budget = max(1, pixelBudget)
        guard pixels > budget else { return input }
        let s = sqrt(budget / pixels)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y))
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return drawn.cgImage
    }
}
