import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import Foundation
import ImageIO
import MapKit
import UIKit

/// Caps simultaneous **`CGImageSource`** thumbnail work app‑wide. **`MKTileOverlay`** fires many concurrent loads; each HEIF decode can briefly allocate a very large buffer before downsample (**jetsam** / **`EXC_RESOURCE`**).
enum ImageIODecodeLimiter {
    private static let semaphore = DispatchSemaphore(value: 1)

    static func synchronizing<T>(_ work: () throws -> T) rethrows -> T {
        semaphore.wait()
        defer { semaphore.signal() }
        return try work()
    }
}

/// One-time “bake” of **`source`** + geographic quad into a **Mercator axis-aligned** texture keyed to **`boundingMapRect`**, so **`MKMapView`** browse mode only stretches a rectangle (no per-frame projective work).
enum OverlayMapBake {
    /// Default baked-output budget (~16.8 MP; equivalent to 4096²).
    private static let defaultOutputPixelBudget: CGFloat = 16_777_216
    /// Larger baked-output budget for heavy sources (~16.8 MP; equivalent to 4096²).
    /// High-zoom detail now comes from per-tile source LOD decoding, so keep browse bake lightweight.
    private static let highResOutputPixelBudget: CGFloat = 16_777_216
    /// Default CI input budget before perspective warp (~67 MP; equivalent to 8192²).
    private static let defaultSourceCIPixelBudget: CGFloat = 67_108_864
    /// CI input budget for very large source rasters (~67 MP; equivalent to 8192²).
    /// Keeps save-time warp memory bounded; tiles recover detail from source LOD path.
    private static let highResSourceCIPixelBudget: CGFloat = 67_108_864

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

    /// Normalized **`CGImage`** for Core Image / OpenCV geometry pipelines.
    static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return drawn.cgImage
    }

    /// Mercator output pixel positions for geographic **`corners`** index order (TL, TR, BR, BL), matching **`CIFilter.perspectiveTransform`** in **`bakeMercatorDisplayTexture`** (Core Image bottom-left origin).
    static func mercatorDestinationPixelPoints(width W: Int, height H: Int, corners: [CLLocationCoordinate2D]) -> [CGPoint]? {
        guard corners.count == 4, W >= 2, H >= 2 else { return nil }
        let bbox = mapBoundingMapRect(for: corners)
        let ox = bbox.origin.x
        let oy = bbox.origin.y
        let bw = bbox.size.width
        let bh = bbox.size.height
        guard bw.isFinite, bh.isFinite, bw > 0, bh > 0 else { return nil }

        let mapPts = corners.map { MKMapPoint($0) }
        let ciH = CGFloat(H)
        var out: [CGPoint] = []
        out.reserveCapacity(4)
        for i in 0..<4 {
            let mp = mapPts[i]
            let px = (mp.x - ox) / bw * CGFloat(W)
            let pyFromNorth = (mp.y - oy) / bh * CGFloat(H)
            let ciPt = CGPoint(x: px, y: ciH - pyFromNorth)
            out.append(ciPt)
        }
        return out
    }

    /// Same corner order as **`mercatorDestinationPixelPoints`**, UIKit / Metal top-down **Y**.
    static func mercatorDestinationPixelPointsTopDown(
        width W: Int,
        height H: Int,
        corners: [CLLocationCoordinate2D]
    ) -> [CGPoint]? {
        guard corners.count == 4, W >= 2, H >= 2 else { return nil }
        let bbox = mapBoundingMapRect(for: corners)
        let ox = bbox.origin.x
        let oy = bbox.origin.y
        let bw = bbox.size.width
        let bh = bbox.size.height
        guard bw.isFinite, bh.isFinite, bw > 0, bh > 0 else { return nil }

        let mapPts = corners.map { MKMapPoint($0) }
        var out: [CGPoint] = []
        out.reserveCapacity(4)
        for i in 0..<4 {
            let mp = mapPts[i]
            let px = (mp.x - ox) / bw * CGFloat(W)
            let pyFromNorth = (mp.y - oy) / bh * CGFloat(H)
            out.append(CGPoint(x: px, y: pyFromNorth))
        }
        return out
    }

    /// Per-tile layout for inverse Metal rendering (map tile → mercator pixel rect → source sample).
    struct MercatorTileLayout {
        let textureCrop: CGRect
        /// Fractional mercator/source pixel crop origin (avoids `.integral` seam drift).
        let exactCropOriginX: CGFloat
        let exactCropOriginY: CGFloat
        let exactCropWidth: CGFloat
        let exactCropHeight: CGFloat
        let outputWidth: Int
        let outputHeight: Int
        let destX: CGFloat
        let destY: CGFloat
        let destWidth: CGFloat
        let destHeight: CGFloat

        /// Destination-space basis for Metal **`renderWarpedTile`** (top-down image Y).
        func destinationBasis() -> (origin: SIMD2<Float>, stepX: SIMD2<Float>, stepY: SIMD2<Float>) {
            let invDestW = 1 / max(destWidth, 1)
            let invDestH = 1 / max(destHeight, 1)
            let stepX = SIMD2<Float>(Float(exactCropWidth * invDestW), 0)
            let stepY = SIMD2<Float>(0, Float(exactCropHeight * invDestH))
            let origin = SIMD2<Float>(
                Float(exactCropOriginX) - Float(destX) * stepX.x,
                Float(exactCropOriginY) - Float(destY) * stepY.y
            )
            return (origin, stepX, stepY)
        }

        var tileFullyCoversOutput: Bool {
            destX <= 0.5
                && destY <= 0.5
                && (destX + destWidth) >= CGFloat(outputWidth) - 0.5
                && (destY + destHeight) >= CGFloat(outputHeight) - 0.5
        }
    }

#if DEBUG
    /// Builds a layout for identity-transform tests (**`destCoord == source pixel`**) on a source crop.
    static func debugIdentityTileLayout(
        sourceWidth: Int,
        sourceHeight: Int,
        crop: CGRect,
        outputWidth: Int,
        outputHeight: Int
    ) -> MercatorTileLayout? {
        guard sourceWidth >= 1, sourceHeight >= 1,
              outputWidth >= 1, outputHeight >= 1,
              crop.width >= 1, crop.height >= 1 else { return nil }
        return MercatorTileLayout(
            textureCrop: crop.integral,
            exactCropOriginX: crop.origin.x,
            exactCropOriginY: crop.origin.y,
            exactCropWidth: crop.width,
            exactCropHeight: crop.height,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            destX: 0,
            destY: 0,
            destWidth: CGFloat(outputWidth),
            destHeight: CGFloat(outputHeight)
        )
    }
#endif

    static func mercatorTileLayout(
        mercatorWidth: Int,
        mercatorHeight: Int,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat
    ) -> MercatorTileLayout? {
        guard let geom = mercatorTileGeometry(
            mercatorWidth: CGFloat(mercatorWidth),
            mercatorHeight: CGFloat(mercatorHeight),
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: contentScale
        ) else { return nil }
        return MercatorTileLayout(
            textureCrop: geom.textureCrop,
            exactCropOriginX: geom.exactCropOriginX,
            exactCropOriginY: geom.exactCropOriginY,
            exactCropWidth: geom.exactCropWidth,
            exactCropHeight: geom.exactCropHeight,
            outputWidth: Int(geom.outputWidth),
            outputHeight: Int(geom.outputHeight),
            destX: geom.destX,
            destY: geom.destY,
            destWidth: geom.destWidth,
            destHeight: geom.destHeight
        )
    }

    // MARK: - Per-tile LOD from compressed source (ImageIO)

    private static let tileRenderCIContext = CIContext(options: [
        .highQualityDownsample: true,
        .cacheIntermediates: false,
    ])
    /// Hard cap on thumbnail longest‑edge per tile decode. **`MKTileOverlay`** requests overlap heavily; **`8192`**-class decodes × parallelism blew past jetsam (**`EXC_RESOURCE`**).
    static let maxThumbnailDecodeSide = 4608
    /// Quantize thumbnail decode targets to improve cache reuse across neighboring tiles.
    private static let thumbnailDecodeBucket: Int = 256
    private static var thumbnailCacheScope = ""
    private final class ThumbnailBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static let thumbnailCache: NSCache<NSString, ThumbnailBox> = {
        let c = NSCache<NSString, ThumbnailBox>()
        c.countLimit = 16
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    /// Clears the thumbnail cache when a new pyramid revision starts (avoids stale entries across edits).
    static func beginThumbnailCacheScope(_ scope: String) {
        if scope != thumbnailCacheScope {
            thumbnailCacheScope = scope
            thumbnailCache.removeAllObjects()
        }
    }

    /// Releases decoded source thumbnails after a pyramid build finishes or is superseded.
    static func endThumbnailCacheScope() {
        thumbnailCache.removeAllObjects()
    }

    /// One map tile as HEIF via Metal inverse rendering from **`sourceRaster`** (delegates to **`OverlayTileRenderer`**).
    static func mercatorTileHEIFDataFromSourceRaster(
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        mercatorPixelWidth W: Int,
        mercatorPixelHeight H: Int,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat,
        maxThumbnailDecodeSideOverride: Int? = nil,
        thumbnailCacheScope: String = ""
    ) -> Data? {
        _ = maxThumbnailDecodeSideOverride
        let request = OverlayTileRenderer.SourceTileRequest(
            sourceRaster: sourceRaster,
            corners: corners,
            mercatorPixelWidth: W,
            mercatorPixelHeight: H,
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: contentScale,
            thumbnailCacheScope: thumbnailCacheScope
        )
        return OverlayTileRenderer.mercatorTileHEIFData(from: request)
    }

    /// Backward-compatible name; prefer **`mercatorTileHEIFDataFromSourceRaster`**.
    static func pngMercatorTileFromSourceRaster(
        sourceRaster: Data,
        corners: [CLLocationCoordinate2D],
        mercatorPixelWidth W: Int,
        mercatorPixelHeight H: Int,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat,
        maxThumbnailDecodeSideOverride: Int? = nil
    ) -> Data? {
        mercatorTileHEIFDataFromSourceRaster(
            sourceRaster: sourceRaster,
            corners: corners,
            mercatorPixelWidth: W,
            mercatorPixelHeight: H,
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: contentScale,
            maxThumbnailDecodeSideOverride: maxThumbnailDecodeSideOverride
        )
    }

    static func nativeMaxZoomLevelFromSourceRaster(
        sourceRaster: Data,
        mapBoundingRect: MKMapRect,
        tileSizePoints: CGFloat,
        screenScale: CGFloat
    ) -> Int {
        guard let sz = intrinsicPixelSize(from: sourceRaster) else { return 0 }
        return nativeMaxZoomLevel(
            intrinsicPixelWidth: sz.width,
            intrinsicPixelHeight: sz.height,
            mapBoundingRect: mapBoundingRect,
            tileSizePoints: tileSizePoints,
            screenScale: screenScale
        )
    }

    /// Highest zoom where physical tile resolution still **underresolves** native source (**legacy ceiling**).
    static func nativeMaxZoomLevel(
        intrinsicPixelWidth: Int,
        intrinsicPixelHeight: Int,
        mapBoundingRect: MKMapRect,
        tileSizePoints: CGFloat,
        screenScale: CGFloat
    ) -> Int {
        let raw = nativeMaxZoomRawValue(
            intrinsicPixelWidth: intrinsicPixelWidth,
            intrinsicPixelHeight: intrinsicPixelHeight,
            mapBoundingRect: mapBoundingRect,
            tileSizePoints: tileSizePoints,
            screenScale: screenScale
        )
        guard raw.isFinite else { return 0 }
        return max(0, Int(floor(raw)))
    }

    /// **maxZ** for runtime-progressive pyramids: lowest zoom that **reaches or exceeds** native source resolution.
    static func nativeOverresolveMaxZoomLevel(
        intrinsicPixelWidth: Int,
        intrinsicPixelHeight: Int,
        mapBoundingRect: MKMapRect,
        tileSizePoints: CGFloat,
        screenScale: CGFloat
    ) -> Int {
        let raw = nativeMaxZoomRawValue(
            intrinsicPixelWidth: intrinsicPixelWidth,
            intrinsicPixelHeight: intrinsicPixelHeight,
            mapBoundingRect: mapBoundingRect,
            tileSizePoints: tileSizePoints,
            screenScale: screenScale
        )
        guard raw.isFinite else { return 0 }
        return max(0, Int(ceil(raw)))
    }

    static func nativeOverresolveMaxZoomLevelFromSourceRaster(
        sourceRaster: Data,
        mapBoundingRect: MKMapRect,
        tileSizePoints: CGFloat,
        screenScale: CGFloat
    ) -> Int {
        guard let sz = intrinsicPixelSize(from: sourceRaster) else { return 0 }
        return nativeOverresolveMaxZoomLevel(
            intrinsicPixelWidth: sz.width,
            intrinsicPixelHeight: sz.height,
            mapBoundingRect: mapBoundingRect,
            tileSizePoints: tileSizePoints,
            screenScale: screenScale
        )
    }

    private static func nativeMaxZoomRawValue(
        intrinsicPixelWidth: Int,
        intrinsicPixelHeight: Int,
        mapBoundingRect: MKMapRect,
        tileSizePoints: CGFloat,
        screenScale: CGFloat
    ) -> Double {
        let pxW = max(1, CGFloat(intrinsicPixelWidth))
        let pxH = max(1, CGFloat(intrinsicPixelHeight))
        let bw = max(1, CGFloat(mapBoundingRect.size.width))
        let bh = max(1, CGFloat(mapBoundingRect.size.height))
        let sourcePixelsPerMapPoint = min(pxW / bw, pxH / bh)
        let tilePixels = max(1, tileSizePoints * max(1, screenScale))
        let world = CGFloat(MKMapRect.world.size.width)
        return log2((sourcePixelsPerMapPoint * world) / tilePixels)
    }

    private struct MercatorTileGeometry {
        let textureCrop: CGRect
        let exactCropOriginX: CGFloat
        let exactCropOriginY: CGFloat
        let exactCropWidth: CGFloat
        let exactCropHeight: CGFloat
        let outputWidth: CGFloat
        let outputHeight: CGFloat
        let destX: CGFloat
        let destY: CGFloat
        let destWidth: CGFloat
        let destHeight: CGFloat
    }

    private static func mercatorTileGeometry(
        mercatorWidth iw: CGFloat,
        mercatorHeight ih: CGFloat,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat
    ) -> MercatorTileGeometry? {
        guard iw > 0, ih > 0 else { return nil }

        let u0 = CGFloat((clipped.origin.x - bbox.origin.x) / bbox.size.width)
        let u1 = CGFloat((clipped.maxX - bbox.origin.x) / bbox.size.width)
        let v0 = CGFloat((clipped.origin.y - bbox.origin.y) / bbox.size.height)
        let v1 = CGFloat((clipped.maxY - bbox.origin.y) / bbox.size.height)

        let exactCropOriginX = u0 * iw
        let exactCropOriginY = v0 * ih
        let exactCropWidth = max(u1 - u0, 0) * iw
        let exactCropHeight = max(v1 - v0, 0) * ih
        let textureCrop = CGRect(
            x: exactCropOriginX,
            y: exactCropOriginY,
            width: exactCropWidth,
            height: exactCropHeight
        ).integral
        guard textureCrop.width >= 1, textureCrop.height >= 1,
              exactCropWidth >= 0.5, exactCropHeight >= 0.5 else { return nil }

        let tw = max(tileRect.width, 1)
        let th = max(tileRect.height, 1)
        let ow = max(1, CGFloat((tileSize.width * contentScale).rounded()))
        let oh = max(1, CGFloat((tileSize.height * contentScale).rounded()))
        let dx = CGFloat((clipped.origin.x - tileRect.origin.x) / tw) * ow
        let dy = CGFloat((clipped.origin.y - tileRect.origin.y) / th) * oh
        let dw = CGFloat(clipped.size.width / tw) * ow
        let dh = CGFloat(clipped.size.height / th) * oh
        guard dw >= 0.5, dh >= 0.5 else { return nil }

        return MercatorTileGeometry(
            textureCrop: textureCrop,
            exactCropOriginX: exactCropOriginX,
            exactCropOriginY: exactCropOriginY,
            exactCropWidth: exactCropWidth,
            exactCropHeight: exactCropHeight,
            outputWidth: ow,
            outputHeight: oh,
            destX: dx,
            destY: dy,
            destWidth: dw,
            destHeight: dh
        )
    }

    static func intrinsicPixelSize(from data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = props[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (w.intValue, h.intValue)
    }

    private static func cgImageThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        ImageIODecodeLimiter.synchronizing {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let side = max(1, maxPixelSize)
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
    }

    private static func cachedCGImageThumbnail(from data: Data, maxPixelSize: Int, cacheScope: String) -> CGImage? {
        let scopePrefix = cacheScope.isEmpty ? "" : "\(cacheScope)-"
        let key = NSString(string: "\(scopePrefix)\(thumbnailCacheKey(data: data, side: max(1, maxPixelSize)))")
        if let box = thumbnailCache.object(forKey: key) {
            return box.image
        }
        guard let decoded = cgImageThumbnail(from: data, maxPixelSize: maxPixelSize) else { return nil }
        let cost = decoded.width * decoded.height * 4
        thumbnailCache.setObject(ThumbnailBox(decoded), forKey: key, cost: cost)
        return decoded
    }

    private static func thumbnailCacheKey(data: Data, side: Int) -> String {
        let head = data.prefix(8).map { String(format: "%02x", $0) }.joined()
        let tail = data.suffix(8).map { String(format: "%02x", $0) }.joined()
        return "\(data.count)-\(side)-\(head)-\(tail)"
    }

    private static func heifData(from cgImage: CGImage, knownOpaque: Bool = false) -> Data? {
        OverlayTileHEIFEncoding.encodeTileImageData(cgImage, knownOpaque: knownOpaque)
    }
}
