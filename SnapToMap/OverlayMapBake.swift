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
    private static let semaphore = DispatchSemaphore(value: 2)

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

    /// Normalized **`CGImage`** for geometry pipelines (OpenCV / Core Image); internal so **`OpenCVBridge`** can reuse the same convention.
    static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return drawn.cgImage
    }

    /// Mercator output pixel positions for geographic **`corners`** index order (TL, TR, BR, BL), matching **`CIFilter.perspectiveTransform`** in **`bakeMercatorDisplayTexture`** (UIKit-style Y down).
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

    // MARK: - Per-tile LOD from compressed source (ImageIO)

    private static let tileRenderCIContext = CIContext(options: [.highQualityDownsample: true])
    /// Hard cap on thumbnail longest‑edge per tile decode. **`MKTileOverlay`** requests overlap heavily; **`8192`**-class decodes × parallelism blew past jetsam (**`EXC_RESOURCE`**).
    private static let maxThumbnailDecodeSide = 4608
    /// Quantize thumbnail decode targets to improve cache reuse across neighboring tiles.
    private static let thumbnailDecodeBucket: Int = 256
    private final class ThumbnailBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static let thumbnailCache: NSCache<NSString, ThumbnailBox> = {
        let c = NSCache<NSString, ThumbnailBox>()
        c.countLimit = 12
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    /// One map tile as PNG: Mercator warp matches **`bakeMercatorDisplayTexture`**, but **`sourceRaster`** is decoded via **`ImageIO`** only as large as this zoom needs.
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
        guard corners.count == 4, W >= 1, H >= 1 else { return nil }
        guard let geom = mercatorTileGeometry(
            mercatorWidth: CGFloat(W),
            mercatorHeight: CGFloat(H),
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: contentScale
        ) else { return nil }

        guard let intrinsic = intrinsicPixelSize(from: sourceRaster) else { return nil }
        let nativeMaxSide = max(intrinsic.width, intrinsic.height)
        let cw = max(geom.textureCrop.width, 1)
        let ch = max(geom.textureCrop.height, 1)
        let decodeNeeded = max(
            geom.outputWidth * CGFloat(W) / cw,
            geom.outputHeight * CGFloat(H) / ch
        )
        let decodeSideCap = max(1, maxThumbnailDecodeSideOverride ?? maxThumbnailDecodeSide)
        let targetDecodeSide = Int(min(CGFloat(decodeSideCap), max(1, decodeNeeded * 1.18)).rounded(.up))
        let thumbnailSide = max(1, min(nativeMaxSide, targetDecodeSide))
        let quantizedSide = max(
            1,
            min(
                nativeMaxSide,
                ((thumbnailSide + thumbnailDecodeBucket - 1) / thumbnailDecodeBucket) * thumbnailDecodeBucket
            )
        )

        guard let cgThumb = cachedCGImageThumbnail(from: sourceRaster, maxPixelSize: quantizedSide) else { return nil }
        let ciInput = CIImage(cgImage: cgThumb)

        let bboxRect = mapBoundingMapRect(for: corners)
        let ox = bboxRect.origin.x
        let oy = bboxRect.origin.y
        let bw = bboxRect.size.width
        let bh = bboxRect.size.height
        guard bw.isFinite, bh.isFinite, bw > 0, bh > 0 else { return nil }

        let mapPts = corners.map { MKMapPoint($0) }
        let ciH = CGFloat(H)
        let cropRect = geom.textureCrop.integral
        guard cropRect.width >= 2, cropRect.height >= 2 else { return nil }
        let localW = cropRect.width
        let localH = cropRect.height
        // geom.textureCrop is in top-down texture coordinates; convert its origin to CI space
        // so localY math stays consistent with ciPt (bottom-left origin).
        let cropRectCIOriginY = ciH - (cropRect.origin.y + cropRect.height)

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = ciInput
        for i in 0..<4 {
            let mp = mapPts[i]
            let px = (mp.x - ox) / bw * CGFloat(W)
            let pyFromNorth = (mp.y - oy) / bh * CGFloat(H)
            // Render in crop-local mercator space to avoid allocating full W×H intermediates per tile.
            let localX = px - cropRect.origin.x
            let localY = (ciH - pyFromNorth) - cropRectCIOriginY
            let ciPt = CGPoint(x: localX, y: localY)
            switch i {
            case 0: filter.topLeft = ciPt
            case 1: filter.topRight = ciPt
            case 2: filter.bottomRight = ciPt
            case 3: filter.bottomLeft = ciPt
            default: break
            }
        }

        guard let warped = filter.outputImage else { return nil }
        let targetExtent = CGRect(x: 0, y: 0, width: localW, height: localH)
        let croppedWarp = warped.cropped(to: targetExtent)
        let clearBackdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: targetExtent)
        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = croppedWarp
        composite.backgroundImage = clearBackdrop
        guard let composited = composite.outputImage?.cropped(to: targetExtent) else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgSlice = tileRenderCIContext.createCGImage(composited, from: targetExtent, format: .RGBA8, colorSpace: colorSpace)
                ?? tileRenderCIContext.createCGImage(composited, from: targetExtent) else {
            return nil
        }

        guard let outSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: Int(geom.outputWidth),
                  height: Int(geom.outputHeight),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: outSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: geom.outputWidth, height: geom.outputHeight))
        let drawY = geom.outputHeight - (geom.destY + geom.destHeight)
        ctx.draw(cgSlice, in: CGRect(x: geom.destX, y: drawY, width: geom.destWidth, height: geom.destHeight))
        guard let outCg = ctx.makeImage() else { return nil }
        return pngData(from: outCg)
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

    /// Same detail limit as **`nativeMaxZoomLevelFromSourceRaster`**, but accepts decoded intrinsic dimensions directly.
    static func nativeMaxZoomLevel(
        intrinsicPixelWidth: Int,
        intrinsicPixelHeight: Int,
        mapBoundingRect: MKMapRect,
        tileSizePoints: CGFloat,
        screenScale: CGFloat
    ) -> Int {
        let pxW = max(1, CGFloat(intrinsicPixelWidth))
        let pxH = max(1, CGFloat(intrinsicPixelHeight))
        let bw = max(1, CGFloat(mapBoundingRect.size.width))
        let bh = max(1, CGFloat(mapBoundingRect.size.height))
        let sourcePixelsPerMapPoint = min(pxW / bw, pxH / bh)
        let tilePixels = max(1, tileSizePoints * max(1, screenScale))
        let world = CGFloat(MKMapRect.world.size.width)
        let raw = log2((sourcePixelsPerMapPoint * world) / tilePixels)
        guard raw.isFinite else { return 0 }
        return max(0, Int(floor(raw)))
    }

    private struct MercatorTileGeometry {
        let textureCrop: CGRect
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

        let textureCrop = CGRect(
            x: u0 * iw,
            y: v0 * ih,
            width: max(u1 - u0, 0) * iw,
            height: max(v1 - v0, 0) * ih
        ).integral
        guard textureCrop.width >= 1, textureCrop.height >= 1 else { return nil }

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
            outputWidth: ow,
            outputHeight: oh,
            destX: dx,
            destY: dy,
            destWidth: dw,
            destHeight: dh
        )
    }

    private static func intrinsicPixelSize(from data: Data) -> (width: Int, height: Int)? {
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

    private static func cachedCGImageThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        let key = NSString(string: thumbnailCacheKey(data: data, side: max(1, maxPixelSize)))
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

    private static func pngData(from cgImage: CGImage) -> Data? {
        OverlayLibrary.encodeTileImageData(cgImage)
    }
}
