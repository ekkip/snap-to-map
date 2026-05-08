import CoreGraphics
import CoreImage
import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers

// MARK: - Protocol

/// Map overlay types produced by **`OverlayMapPresentation`** for unified hit-testing, opacity, and removal.
protocol SnapRasterMapOverlay: MKOverlay {
    var overlayID: UUID { get }
    /// When **`true`**, browse-mode opacity uses **`committed`** until drag ends (see **`RasterMapOpacityBag`**).
    var presentationUsesHeavyOpacityPath: Bool { get }
    var opacityBag: RasterMapOpacityBag? { get }
}

extension ImageRasterMapOverlay: SnapRasterMapOverlay {
    var presentationUsesHeavyOpacityPath: Bool { largeImage }
}

// MARK: - Tile overlay (≥ threshold)

/// Serves **`MKTileOverlayPath`** tiles by cropping the baked mercator **`UIImage`**, avoiding one giant `draw` / full-bitmap crop for each visible map rect.
final class BakedImageMapTileOverlay: MKTileOverlay, SnapRasterMapOverlay {
    let overlayID: UUID
    let image: UIImage
    private let imageBoundingMapRect: MKMapRect
    private let tileCache: TileCache
    private let transparentTileDataByScale = NSCache<NSString, NSData>()
    private static let tileDecodeCIContext = CIContext(options: [.highQualityDownsample: true])

    weak var opacityBag: RasterMapOpacityBag?

    var presentationUsesHeavyOpacityPath: Bool { true }

    init(overlayID: UUID, image: UIImage, mapBoundingRect: MKMapRect, opacityBag: RasterMapOpacityBag) {
        self.overlayID = overlayID
        self.image = image
        self.imageBoundingMapRect = mapBoundingRect
        self.opacityBag = opacityBag
        self.tileCache = TileCache(
            overlayID: overlayID,
            image: image,
            mapBoundingRect: mapBoundingRect
        )
        super.init(urlTemplate: "snap-to-map-baked://local")
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        maximumZ = 22
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var boundingMapRect: MKMapRect { imageBoundingMapRect }

    override var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: imageBoundingMapRect.midX, y: imageBoundingMapRect.midY).coordinate
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        tileCache.loadTile(path: path, tileSize: tileSize, geometryFlipped: isGeometryFlipped) { [weak self] data in
            guard let self else {
                result(nil, nil)
                return
            }
            guard let data else {
                result(self.transparentTilePNG(points: self.tileSize, scale: path.contentScaleFactor), nil)
                return
            }
            result(data, nil)
        }
    }

    /// Mercator **`MKMapRect`** covered by **`path`** (same tiling as **`MKTileOverlay`** / `MKMapRect.world`).
    private static func mapRect(for path: MKTileOverlayPath, geometryFlipped: Bool) -> MKMapRect {
        let world = MKMapRect.world
        let n = pow(2.0, Double(path.z))
        let tileW = world.size.width / n
        let tileH = world.size.height / n
        let ox = world.origin.x + Double(path.x) * tileW
        var oy = world.origin.y + Double(path.y) * tileH
        if geometryFlipped {
            oy = world.origin.y + world.size.height - Double(path.y + 1) * tileH
        }
        return MKMapRect(origin: MKMapPoint(x: ox, y: oy), size: MKMapSize(width: tileW, height: tileH))
    }

    private func transparentTilePNG(points: CGSize, scale: CGFloat) -> Data {
        let key = NSString(string: "transparent-\(Int((scale * 100).rounded()))")
        if let cached = transparentTileDataByScale.object(forKey: key) {
            return cached as Data
        }
        let pxW = max(1, Int((points.width * scale).rounded()))
        let pxH = max(1, Int((points.height * scale).rounded()))
        let data = Self.transparentPNGData(width: pxW, height: pxH) ?? Data()
        transparentTileDataByScale.setObject(data as NSData, forKey: key)
        return data
    }

    private static func pngTileData(
        sourceCGImage: CGImage,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat
    ) -> Data? {
        let iw = CGFloat(sourceCGImage.width)
        let ih = CGFloat(sourceCGImage.height)
        guard iw > 0, ih > 0 else { return nil }

        let u0 = CGFloat((clipped.origin.x - bbox.origin.x) / bbox.size.width)
        let u1 = CGFloat((clipped.maxX - bbox.origin.x) / bbox.size.width)
        let v0 = CGFloat((clipped.origin.y - bbox.origin.y) / bbox.size.height)
        let v1 = CGFloat((clipped.maxY - bbox.origin.y) / bbox.size.height)

        let srcRect = CGRect(
            x: u0 * iw,
            y: v0 * ih,
            width: max(u1 - u0, 0) * iw,
            height: max(v1 - v0, 0) * ih
        ).integral
        guard srcRect.width >= 1, srcRect.height >= 1,
              let cropped = sourceCGImage.cropping(to: srcRect) else {
            return nil
        }

        let tw = max(tileRect.width, 1)
        let th = max(tileRect.height, 1)
        let ow = max(1, CGFloat((tileSize.width * contentScale).rounded()))
        let oh = max(1, CGFloat((tileSize.height * contentScale).rounded()))
        let dx = CGFloat((clipped.origin.x - tileRect.origin.x) / tw) * ow
        let dy = CGFloat((clipped.origin.y - tileRect.origin.y) / th) * oh
        let dw = CGFloat(clipped.size.width / tw) * ow
        let dh = CGFloat(clipped.size.height / th) * oh
        guard dw >= 0.5, dh >= 0.5 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: Int(ow),
                  height: Int(oh),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: ow, height: oh))
        let drawY = oh - (dy + dh)
        ctx.draw(cropped, in: CGRect(x: dx, y: drawY, width: dw, height: dh))
        guard let out = ctx.makeImage() else { return nil }
        return encodePNG(cgImage: out)
    }

    private static func encodePNG(cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func transparentPNGData(width: Int, height: Int) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cg = ctx.makeImage() else { return nil }
        return encodePNG(cgImage: cg)
    }

    /// Lazy tile pyramid cache: first request renders/encodes the tile, subsequent requests hit memory or disk.
    private final class TileCache {
        private struct ClampedRequest {
            let z: Int
            let x: Int
            let y: Int
            let shift: Int
            let childX: Int
            let childY: Int
            let scale100: Int
        }

        private let overlayID: UUID
        private let sourceCGImage: CGImage
        private let mapBoundingRect: MKMapRect
        private let nativeMaxZ: Int
        private let memoryCache = NSCache<NSString, NSData>()
        private let ioQueue = DispatchQueue(label: "snap-to-map.tile-cache", qos: .userInitiated, attributes: .concurrent)
        private let fm = FileManager.default
        private let cacheRootURL: URL

        init(overlayID: UUID, image: UIImage, mapBoundingRect: MKMapRect) {
            self.overlayID = overlayID
            self.mapBoundingRect = mapBoundingRect
            // Tile path must stay CoreGraphics-only; rely on pre-decoded CGImage.
            if let cg = image.cgImage {
                self.sourceCGImage = cg
            } else if let ci = CIImage(image: image) {
                let extent = ci.extent.integral
                if extent.width >= 1, extent.height >= 1,
                   let decoded = BakedImageMapTileOverlay.tileDecodeCIContext.createCGImage(ci, from: extent) {
                    self.sourceCGImage = decoded
                } else {
                    self.sourceCGImage = Self.make1x1TransparentCGImage()
                }
            } else {
                self.sourceCGImage = Self.make1x1TransparentCGImage()
            }
            self.cacheRootURL = Self.makeCacheRootURL(overlayID: overlayID, image: image, mapBoundingRect: mapBoundingRect)
            self.nativeMaxZ = Self.computeNativeMaxZoomLevel(
                sourceCGImage: self.sourceCGImage,
                mapBoundingRect: mapBoundingRect,
                tileSizePoints: 256,
                screenScale: UIScreen.main.scale
            )
            self.memoryCache.countLimit = 512
            self.memoryCache.totalCostLimit = 64 * 1024 * 1024
            try? fm.createDirectory(at: cacheRootURL, withIntermediateDirectories: true)
        }

        func loadTile(path: MKTileOverlayPath, tileSize: CGSize, geometryFlipped: Bool, completion: @escaping (Data?) -> Void) {
            ioQueue.async {
                let key = self.cacheKey(path: path)
                if let mem = self.memoryCache.object(forKey: key) {
                    completion(mem as Data)
                    return
                }
                let diskURL = self.diskURL(path: path)
                if let disk = try? Data(contentsOf: diskURL) {
                    self.storeInMemory(disk, key: key)
                    completion(disk)
                    return
                }
                let req = self.clampedRequest(for: path)
                let clampedPath = MKTileOverlayPath(
                    x: req.x,
                    y: req.y,
                    z: req.z,
                    contentScaleFactor: path.contentScaleFactor
                )
                guard let base = self.loadOrRenderExactTile(path: clampedPath, tileSize: tileSize, geometryFlipped: geometryFlipped) else {
                    completion(nil)
                    return
                }
                let served: Data?
                if req.shift == 0 {
                    served = base
                } else {
                    served = Self.makeOverzoomedChildTile(
                        parentTileData: base,
                        shift: req.shift,
                        childX: req.childX,
                        childY: req.childY,
                        contentScale: path.contentScaleFactor,
                        tileSize: tileSize
                    )
                }
                guard let served else {
                    completion(nil)
                    return
                }
                self.storeInMemory(served, key: key)
                // Do not persist overzoom children as deeper z/x/y tiles on disk.
                // Disk cache should stop at native/clamped tile levels.
                if req.shift == 0 {
                    self.storeOnDisk(served, at: diskURL)
                }
                completion(served)
            }
        }

        private func clampedRequest(for path: MKTileOverlayPath) -> ClampedRequest {
            let z = min(path.z, nativeMaxZ)
            let shift = max(0, path.z - z)
            let scale = 1 << shift
            let x = path.x / scale
            let y = path.y / scale
            let childMask = (1 << shift) - 1
            let childX = shift == 0 ? 0 : (path.x & childMask)
            let childY = shift == 0 ? 0 : (path.y & childMask)
            let scale100 = Int((path.contentScaleFactor * 100).rounded())
            return ClampedRequest(z: z, x: x, y: y, shift: shift, childX: childX, childY: childY, scale100: scale100)
        }

        private func loadOrRenderExactTile(path: MKTileOverlayPath, tileSize: CGSize, geometryFlipped: Bool) -> Data? {
            let key = cacheKey(path: path)
            if let mem = memoryCache.object(forKey: key) {
                return mem as Data
            }
            let url = diskURL(path: path)
            if let disk = try? Data(contentsOf: url) {
                storeInMemory(disk, key: key)
                return disk
            }
            let tileRect = BakedImageMapTileOverlay.mapRect(for: path, geometryFlipped: geometryFlipped)
            let clipped = mapBoundingRect.intersection(tileRect)
            guard !clipped.isNull, !clipped.isEmpty, clipped.size.width > 0, clipped.size.height > 0 else {
                return nil
            }
            guard let data = BakedImageMapTileOverlay.pngTileData(
                sourceCGImage: sourceCGImage,
                tileRect: tileRect,
                bbox: mapBoundingRect,
                clipped: clipped,
                tileSize: tileSize,
                contentScale: path.contentScaleFactor
            ) else {
                return nil
            }
            storeInMemory(data, key: key)
            storeOnDisk(data, at: url)
            return data
        }

        private static func computeNativeMaxZoomLevel(
            sourceCGImage: CGImage,
            mapBoundingRect: MKMapRect,
            tileSizePoints: CGFloat,
            screenScale: CGFloat
        ) -> Int {
            let pxW = max(1, CGFloat(sourceCGImage.width))
            let pxH = max(1, CGFloat(sourceCGImage.height))
            let bw = max(1, CGFloat(mapBoundingRect.size.width))
            let bh = max(1, CGFloat(mapBoundingRect.size.height))
            let sourcePixelsPerMapPoint = min(pxW / bw, pxH / bh)
            let tilePixels = max(1, tileSizePoints * max(1, screenScale))
            let world = CGFloat(MKMapRect.world.size.width)
            let raw = log2((sourcePixelsPerMapPoint * world) / tilePixels)
            guard raw.isFinite else { return 0 }
            return max(0, Int(floor(raw)))
        }

        private static func makeCacheRootURL(overlayID: UUID, image: UIImage, mapBoundingRect: MKMapRect) -> URL {
            let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let sig = cacheSignature(image: image, mapBoundingRect: mapBoundingRect)
            return cacheBase
                .appendingPathComponent("snap-to-map-tile-cache", isDirectory: true)
                .appendingPathComponent(overlayID.uuidString, isDirectory: true)
                .appendingPathComponent(sig, isDirectory: true)
        }

        private static func cacheSignature(image: UIImage, mapBoundingRect: MKMapRect) -> String {
            let pxW = Int((image.size.width * image.scale).rounded())
            let pxH = Int((image.size.height * image.scale).rounded())
            func q(_ v: Double) -> Int64 { Int64((v * 1_000_000).rounded()) }
            return "v6-\(pxW)x\(pxH)-\(q(mapBoundingRect.origin.x))-\(q(mapBoundingRect.origin.y))-\(q(mapBoundingRect.size.width))-\(q(mapBoundingRect.size.height))"
        }

        private func cacheKey(path: MKTileOverlayPath) -> NSString {
            let scale = Int((path.contentScaleFactor * 100).rounded())
            return NSString(string: "\(path.z)/\(path.x)/\(path.y)@\(scale)")
        }

        private func diskURL(path: MKTileOverlayPath) -> URL {
            let scale = Int((path.contentScaleFactor * 100).rounded())
            return cacheRootURL
                .appendingPathComponent("z\(path.z)", isDirectory: true)
                .appendingPathComponent("x\(path.x)", isDirectory: true)
                .appendingPathComponent("y\(path.y)@\(scale).png", isDirectory: false)
        }

        private func storeInMemory(_ data: Data, key: NSString) {
            memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
        }

        private func storeOnDisk(_ data: Data, at url: URL) {
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }

        private static func makeOverzoomedChildTile(
            parentTileData: Data,
            shift: Int,
            childX: Int,
            childY: Int,
            contentScale: CGFloat,
            tileSize: CGSize
        ) -> Data? {
            guard shift > 0,
                  let src = CGImageSourceCreateWithData(parentTileData as CFData, nil),
                  let parentCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let pw = max(1, parentCG.width)
            let ph = max(1, parentCG.height)
            let n = 1 << shift
            let sx = CGFloat(childX) * (CGFloat(pw) / CGFloat(n))
            let sy = CGFloat(childY) * (CGFloat(ph) / CGFloat(n))
            let sw = CGFloat(pw) / CGFloat(n)
            let sh = CGFloat(ph) / CGFloat(n)
            let srcRect = CGRect(x: sx, y: sy, width: sw, height: sh)
                .integral
                .intersection(CGRect(x: 0, y: 0, width: pw, height: ph))
            guard srcRect.width >= 1, srcRect.height >= 1,
                  let cropped = parentCG.cropping(to: srcRect),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let outW = Int(max(1, (tileSize.width * contentScale).rounded()))
            let outH = Int(max(1, (tileSize.height * contentScale).rounded()))
            guard let ctx = CGContext(
                data: nil,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.clear(CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            guard let out = ctx.makeImage() else { return nil }
            return BakedImageMapTileOverlay.encodePNG(cgImage: out)
        }

        private static func make1x1TransparentCGImage() -> CGImage {
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            if let img = ctx?.makeImage() { return img }
            let bytes: [UInt8] = [0, 0, 0, 0]
            let data = Data(bytes)
            if let provider = CGDataProvider(data: data as CFData),
               let img = CGImage(
                   width: 1,
                   height: 1,
                   bitsPerComponent: 8,
                   bitsPerPixel: 32,
                   bytesPerRow: 4,
                   space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider,
                   decode: nil,
                   shouldInterpolate: false,
                   intent: .defaultIntent
               ) {
                return img
            }
            fatalError("Failed to create fallback transparent CGImage")
        }
    }
}

// MARK: - Façade

/// Chooses **`ImageRasterMapOverlay`** (fast opacity drags) vs **`BakedImageMapTileOverlay`** when the
/// overlay’s **source** exceeds **`OverlayLibrary.largeRasterOverlayPixelThresholdExclusive`** (>100 MP), via
/// **`OverlayItem.usesTiledMapPresentation`** (frozen at item creation).
///
/// **Note:** Small sources still use **`ImageRasterMapOverlay`** with **`MKOverlayRenderer`**; MapKit calls
/// **`draw(mapRect:zoomScale:in:)`** for each visible region while panning — that is **not**
/// **`MKTileOverlay.loadTile`** (log `loadTile` only on **`BakedImageMapTileOverlay`** to tell them apart).
enum OverlayMapPresentation {
    case raster(ImageRasterMapOverlay)
    case tiled(BakedImageMapTileOverlay)

    static func make(
        overlayID: UUID,
        mapDisplayImage: UIImage,
        usesTiledMapPresentation: Bool,
        mapBoundingRect: MKMapRect,
        opacityBag: RasterMapOpacityBag
    ) -> OverlayMapPresentation {
        if usesTiledMapPresentation {
            return .tiled(
                BakedImageMapTileOverlay(
                    overlayID: overlayID,
                    image: mapDisplayImage,
                    mapBoundingRect: mapBoundingRect,
                    opacityBag: opacityBag
                )
            )
        }
        return .raster(
            ImageRasterMapOverlay(
                overlayID: overlayID,
                image: mapDisplayImage,
                mapBoundingRect: mapBoundingRect,
                largeImage: false,
                opacityBag: opacityBag
            )
        )
    }

    var mkOverlay: MKOverlay {
        switch self {
        case .raster(let o): return o
        case .tiled(let o): return o
        }
    }

    var snapRaster: SnapRasterMapOverlay { mkOverlay as! SnapRasterMapOverlay }

    var overlayID: UUID { snapRaster.overlayID }
}
