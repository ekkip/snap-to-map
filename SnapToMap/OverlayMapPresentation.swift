import CoreGraphics
import CoreImage
import ImageIO
import MapKit
import UIKit

enum TileDiagFileLog {
    private static let queue = DispatchQueue(label: "snap-to-map.tile-diag-file-log", qos: .utility)
    private static var sessionInitialized = false

    static func append(_ line: String) {
        queue.async {
            let fm = FileManager.default
            guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = base.appendingPathComponent("snap-tile-diag.log", isDirectory: false)
            if !sessionInitialized {
                sessionInitialized = true
                try? fm.removeItem(at: url)
                let header = "=== session \(Date()) ===\n"
                try? header.data(using: .utf8)?.write(to: url, options: .atomic)
            }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

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

/// Serves **`MKTileOverlayPath`** tiles from the mercator browse texture; large overlays may **`ImageIO`**-decode only the subsample needed per zoom (see **`TileCache.RasterBacking`**).
final class BakedImageMapTileOverlay: MKTileOverlay, SnapRasterMapOverlay {
    private static let agentDebugLogPath = "/Users/ekki/Library/CloudStorage/Dropbox/Programmator/GITHUB/snap-to-map/.cursor/debug-2c9d13.log"
    private static let agentDebugSessionId = "2c9d13"

    private static func agentDebugLog(
        runId: String,
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        let now = Date().timeIntervalSince1970
        let ts = Int64((now * 1000.0).rounded())
        let eventID = "log_\(ts)_\(UInt64.random(in: 0...UInt64.max))"
        let payload: [String: Any] = [
            "sessionId": agentDebugSessionId,
            "id": eventID,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": ts,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: encoded, encoding: .utf8) else { return }
        line.append("\n")
        let logURL = URL(fileURLWithPath: agentDebugLogPath, isDirectory: false)
        let bytes = Data(line.utf8)
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: bytes)
                } catch {
                    return
                }
            }
        } else {
            try? bytes.write(to: logURL, options: .atomic)
        }
    }

    let overlayID: UUID
    let image: UIImage
    private let imageBoundingMapRect: MKMapRect
    private let tileCache: TileCache
    private let transparentTileDataByScale = NSCache<NSString, NSData>()
    private static let tileDecodeCIContext = CIContext(options: [.highQualityDownsample: true])

    private let tilePyramidDiskRoot: URL?
    private enum TilePyramidYIndexMode: String {
        case xyzTopDown
        case legacyFlipped
    }
    private let tilePyramidYIndexMode: TilePyramidYIndexMode
    /// Compared against **`OverlayTilePyramidRuntimeInfo.revision`** when deciding whether to recycle an existing renderer instance.
    let tilePyramidIdentityRevision: Int64
    let tilePyramidRuntimeInfo: OverlayTilePyramidRuntimeInfo?
    /// Metadata/native ceiling used for overzoom parent lookup (may exceed what is on disk yet).
    private let persistedPyramidMaximumZ: Int?
    /// Highest **`z`** directory with tile files on disk for this revision.
    private let diskPyramidMaximumZ: Int
    /// True while full-resolution levels are still being materialized in background.
    private let persistedPyramidRefinementInProgress: Bool
    private let tileDiskReadQueue = DispatchQueue(label: "snap-to-map.tile-disk-read", qos: .userInitiated)
    private let diskTileMemoryCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 160
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    private static let tileLoadDiagGate = NSLock()
    private static var tileLoadDiagCounter = 0
    private static var tileMissDiagCounter = 0
    private static var tileRequestDiagCounter = 0

    weak var opacityBag: RasterMapOpacityBag?

    var presentationUsesHeavyOpacityPath: Bool { true }

    init(
        overlayID: UUID,
        image: UIImage,
        mapBoundingRect: MKMapRect,
        opacityBag: RasterMapOpacityBag,
        sourceRasterForTileLOD: Data?,
        geographicCorners: [CLLocationCoordinate2D],
        tilePyramidDiskRoot: URL?,
        tilePyramidRuntime: OverlayTilePyramidRuntimeInfo?
    ) {
        self.overlayID = overlayID
        self.image = image
        self.imageBoundingMapRect = mapBoundingRect
        self.opacityBag = opacityBag
        let cache = TileCache(
            overlayID: overlayID,
            displayReferenceImage: image,
            mapBoundingRect: mapBoundingRect,
            sourceRasterForTileLOD: Self.sourceRasterForLazyTileLOD(
                sourceRasterForTileLOD: sourceRasterForTileLOD,
                tilePyramidRuntime: tilePyramidRuntime
            ),
            geographicCorners: geographicCorners
        )
        self.tileCache = cache

        let resolvedPyramidRoot: URL? = {
            guard let runtime = tilePyramidRuntime,
                  runtime.minimumZoom >= 0,
                  runtime.maximumZoom >= runtime.minimumZoom,
                  let root = tilePyramidDiskRoot,
                  FileManager.default.fileExists(atPath: root.path) else { return nil }
            return root
        }()
        self.tilePyramidDiskRoot = resolvedPyramidRoot
        self.tilePyramidYIndexMode = Self.resolvePyramidYIndexMode(pyramidRoot: resolvedPyramidRoot)
        self.tilePyramidIdentityRevision = tilePyramidRuntime?.revision ?? -1
        self.tilePyramidRuntimeInfo = tilePyramidRuntime
        let metaCeiling = tilePyramidRuntime.map { Int($0.fullMaximumZoom >= 0 ? $0.fullMaximumZoom : $0.maximumZoom) }
        let scannedDiskMaxZ = resolvedPyramidRoot.map { OverlayLibrary.diskMaximumZoomLevel(pyramidRoot: $0) } ?? -1
        self.diskPyramidMaximumZ = scannedDiskMaxZ
        self.persistedPyramidMaximumZ = (resolvedPyramidRoot != nil) ? metaCeiling : nil
        self.persistedPyramidRefinementInProgress = tilePyramidRuntime?.refinementInProgress ?? false
        let overlayTag = String(overlayID.uuidString.prefix(8))
        if let runtime = tilePyramidRuntime {
            let rootLabel = resolvedPyramidRoot?.path ?? "(nil)"
            print("[TileDiag] tileOverlay.init id=\(overlayTag) runtimeRev=\(runtime.revision) minZ=\(runtime.minimumZoom) advertisedMaxZ=\(runtime.maximumZoom) fullMaxZ=\(runtime.fullMaximumZoom) diskMaxZ=\(scannedDiskMaxZ) yMode=\(tilePyramidYIndexMode.rawValue) root=\(rootLabel)")
        } else {
            print("[TileDiag] tileOverlay.init id=\(overlayTag) runtime=nil yMode=\(tilePyramidYIndexMode.rawValue)")
        }

        super.init(urlTemplate: "snap-to-map-baked://local")
        canReplaceMapContent = false
        tileSize = OverlayLibrary.logicalTileSize
        // Keep runtime tile addressing in standard XYZ (top-left origin).
        // Persisted-pyramid loading includes a legacy y-flip fallback.
        isGeometryFlipped = false
        if resolvedPyramidRoot != nil, let runtime = tilePyramidRuntime {
            minimumZ = Int(runtime.minimumZoom)
            // Allow renderer requests above persisted max so custom overzoom path can serve tiles.
            maximumZ = 22
        } else {
            minimumZ = 0
            maximumZ = min(22, cache.nativeMaximumZoomForOverlay)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var boundingMapRect: MKMapRect { imageBoundingMapRect }

    override var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: imageBoundingMapRect.midX, y: imageBoundingMapRect.midY).coordinate
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
		print("")
		if let root = tilePyramidDiskRoot {
			let url = OverlayLibrary.tileDataFileURL(pyramidRoot: root, path: path)
			print("READ TILE: (z: \(path.z), x: \(path.x), y: \(path.y), scale: \(path)) -> \(url)")
            return url
        }
		print("url(forTilePath:\(path)) – super: \(super.url(forTilePath: path))")
        return super.url(forTilePath: path)
    }

    private func registerTileLoadSample(kind: String, path: MKTileOverlayPath, byteCount: Int?) {
		print("\(#function) – kind: \(kind), path: \(path), byteCount: \(byteCount ?? -1)")
        Self.tileLoadDiagGate.lock()
        Self.tileLoadDiagCounter += 1
        let n = Self.tileLoadDiagCounter
        Self.tileLoadDiagGate.unlock()
        guard n <= 16 || n % 48 == 0 else { return }
        let bytesLabel = byteCount.map { String($0) } ?? "nil"
        SnapMemoryInstrumentation.checkpoint(
            "tile.load \(kind) id=\(overlayID.uuidString.prefix(8))… z=\(path.z) \(path.x),\(path.y) scale=\(path.contentScaleFactor) bytes=\(bytesLabel) sample#\(n)"
        )
        TileDiagFileLog.append("[TileDiagFile] load kind=\(kind) id=\(overlayID.uuidString.prefix(8)) z=\(path.z) x=\(path.x) y=\(path.y) scale=\(path.contentScaleFactor) bytes=\(bytesLabel) sample=\(n)")
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
		print("LOAD TILE: (z: \(path.z), x: \(path.x), y: \(path.y), scale: \(path)) <- tileCache")
        Self.tileLoadDiagGate.lock()
        Self.tileRequestDiagCounter += 1
        let reqN = Self.tileRequestDiagCounter
        Self.tileLoadDiagGate.unlock()
        if reqN <= 64 || reqN % 200 == 0 {
            TileDiagFileLog.append("[TileDiagFile] request id=\(overlayID.uuidString.prefix(8)) n=\(reqN) z=\(path.z) x=\(path.x) y=\(path.y) scale=\(path.contentScaleFactor)")
        }
        let persistedCeiling = persistedPyramidMaximumZ ?? maximumZ
        if path.z >= persistedCeiling - 2 || path.z > persistedCeiling {
            // #region agent log
            Self.agentDebugLog(
                runId: "pre-fix",
                hypothesisId: "H7_overzoom_path_selection",
                location: "OverlayMapPresentation.swift:loadTile.entry",
                message: "incoming tile request",
                data: [
                    "overlayTag": String(overlayID.uuidString.prefix(8)),
                    "z": path.z,
                    "x": path.x,
                    "y": path.y,
                    "scale": path.contentScaleFactor,
                    "minimumZ": minimumZ,
                    "maximumZ": maximumZ,
                    "persistedMaximumZ": persistedCeiling,
                    "hasPyramidRoot": tilePyramidDiskRoot != nil,
                    "requestN": reqN,
                ]
            )
            // #endregion
        }
        if let root = tilePyramidDiskRoot {
            let preferredPath = Self.path(path, remappedFor: tilePyramidYIndexMode) ?? path
            let fallbackPath = Self.yFlippedPath(path)
            tileDiskReadQueue.async { [weak self] in
                guard let self else {
                    result(nil, nil)
                    return
                }
                let preferredCandidateURLs = OverlayLibrary.tileCandidateFileURLs(pyramidRoot: root, path: preferredPath)
                var candidateURLs = preferredCandidateURLs
                if let fallbackPath {
                    let fallbackCandidates = OverlayLibrary.tileCandidateFileURLs(pyramidRoot: root, path: fallbackPath)
                    let existing = Set(candidateURLs.map(\.path))
                    for url in fallbackCandidates where !existing.contains(url.path) {
                        candidateURLs.append(url)
                    }
                }
                for (idx, candidateURL) in candidateURLs.enumerated() {
                    let pathKey = NSString(string: candidateURL.path)
                    if let cached = self.diskTileMemoryCache.object(forKey: pathKey) {
                        let data = cached as Data
                        let kind: String
                        if idx == 0 {
                            kind = "pyramid.memCacheHit.\(self.tilePyramidYIndexMode.rawValue)"
                        } else {
                            kind = "pyramid.memCacheHit.yFlipFallback"
                        }
                        self.registerTileLoadSample(kind: kind, path: path, byteCount: data.count)
                        result(data, nil)
                        return
                    }
                    if let data = try? Data(contentsOf: candidateURL) {
                        let kind: String
                        if idx == 0 {
                            kind = "pyramid.diskRead.\(self.tilePyramidYIndexMode.rawValue)"
                        } else {
                            kind = "pyramid.diskRead.yFlipFallback"
                        }
                        self.registerTileLoadSample(kind: kind, path: path, byteCount: data.count)
                        self.diskTileMemoryCache.setObject(data as NSData, forKey: pathKey, cost: data.count)
                        result(data, nil)
                        return
                    }
                }
                if path.z > 0 {
                    let startParentZ = self.diskPyramidMaximumZ >= 0
                        ? min(path.z - 1, self.diskPyramidMaximumZ)
                        : path.z - 1
                    if let overzoomed = self.overzoomedTileFromNearestDiskParent(
                        path: path,
                        pyramidRoot: root,
                        startParentZ: startParentZ
                    ) {
                        self.registerTileLoadSample(kind: "pyramid.overzoomFromDiskParent", path: path, byteCount: overzoomed.count)
                        for url in preferredCandidateURLs {
                            self.diskTileMemoryCache.setObject(overzoomed as NSData, forKey: NSString(string: url.path), cost: overzoomed.count)
                        }
                        result(overzoomed, nil)
                        return
                    }
                }
                let preferredExists = OverlayLibrary.tileCandidateFileURLs(pyramidRoot: root, path: preferredPath).contains {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                let fallbackExists = fallbackPath.map { fallback in
                    OverlayLibrary.tileCandidateFileURLs(pyramidRoot: root, path: fallback).contains { url in
                        FileManager.default.fileExists(atPath: url.path)
                    }
                } ?? false
                print("\(#function) – path: \(path) – no data (mode=\(self.tilePyramidYIndexMode.rawValue), preferredExists=\(preferredExists), fallbackExists=\(fallbackExists))")
                Self.tileLoadDiagGate.lock()
                Self.tileMissDiagCounter += 1
                let missN = Self.tileMissDiagCounter
                Self.tileLoadDiagGate.unlock()
                if missN <= 24 || missN % 64 == 0 {
                    let preferredLabel = OverlayLibrary.tileCandidateFileURLs(pyramidRoot: root, path: preferredPath).map(\.lastPathComponent).joined(separator: "|")
                    print("[TileDiag] tileOverlay.miss id=\(self.overlayID.uuidString.prefix(8)) z=\(path.z) x=\(path.x) y=\(path.y) scale=\(path.contentScaleFactor) mode=\(self.tilePyramidYIndexMode.rawValue) preferred=\(preferredLabel) preferredExists=\(preferredExists) fallbackExists=\(fallbackExists) miss#\(missN)")
                    TileDiagFileLog.append("[TileDiagFile] miss id=\(self.overlayID.uuidString.prefix(8)) n=\(missN) z=\(path.z) x=\(path.x) y=\(path.y) scale=\(path.contentScaleFactor) mode=\(self.tilePyramidYIndexMode.rawValue) preferredExists=\(preferredExists) fallbackExists=\(fallbackExists)")
                }
                // Fallback: if persisted pyramid misses, render on-demand from lazy tile cache
                // rather than serving transparent gaps at higher zoom levels.
                self.tileCache.loadTile(path: path, tileSize: self.tileSize, geometryFlipped: self.isGeometryFlipped) { fallbackData in
                    if self.persistedPyramidRefinementInProgress, path.z > self.diskPyramidMaximumZ {
                        // During refinement, avoid decoding the full source for levels not on disk yet.
                        result(self.transparentTilePNG(points: self.tileSize, scale: path.contentScaleFactor), nil)
                        return
                    }
                    if let fallbackData {
                        self.registerTileLoadSample(kind: "pyramid.missFallback.lazy", path: path, byteCount: fallbackData.count)
                        TileDiagFileLog.append("[TileDiagFile] missFallback.lazy id=\(self.overlayID.uuidString.prefix(8)) z=\(path.z) x=\(path.x) y=\(path.y) scale=\(path.contentScaleFactor) bytes=\(fallbackData.count)")
                        result(fallbackData, nil)
                    } else {
                        result(self.transparentTilePNG(points: self.tileSize, scale: path.contentScaleFactor), nil)
                    }
                }
            }
            return
        }
        tileCache.loadTile(path: path, tileSize: tileSize, geometryFlipped: isGeometryFlipped) { [weak self] data in
            guard let self else {
                result(nil, nil)
                return
            }
            self.registerTileLoadSample(kind: "lazy.tileCache", path: path, byteCount: data?.count)
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

    private static func yFlippedPath(_ path: MKTileOverlayPath) -> MKTileOverlayPath? {
        guard path.z >= 0, path.z < 31 else { return nil }
        let rowCount = 1 << path.z
        guard rowCount > 0 else { return nil }
        let flippedY = rowCount - 1 - path.y
        guard flippedY >= 0, flippedY < rowCount else { return nil }
        return MKTileOverlayPath(
            x: path.x,
            y: flippedY,
            z: path.z,
            contentScaleFactor: path.contentScaleFactor
        )
    }

    private static func path(_ path: MKTileOverlayPath, remappedFor mode: TilePyramidYIndexMode) -> MKTileOverlayPath? {
        switch mode {
        case .xyzTopDown:
            return path
        case .legacyFlipped:
            return yFlippedPath(path)
        }
    }

    private static func sourceRasterForLazyTileLOD(
        sourceRasterForTileLOD: Data?,
        tilePyramidRuntime: OverlayTilePyramidRuntimeInfo?
    ) -> Data? {
        guard let sourceRasterForTileLOD, !sourceRasterForTileLOD.isEmpty else { return nil }
        if let runtime = tilePyramidRuntime {
            if runtime.refinementInProgress || runtime.minimumZoom < 0 {
                return nil
            }
        }
        return sourceRasterForTileLOD
    }

    private static func resolvePyramidYIndexMode(pyramidRoot: URL?) -> TilePyramidYIndexMode {
        guard let pyramidRoot else { return .xyzTopDown }
        let metaURL = pyramidRoot.appendingPathComponent("pyramid-meta.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let yIndexModeRaw = obj["yIndexMode"] as? String,
              let yIndexMode = TilePyramidYIndexMode(rawValue: yIndexModeRaw) else {
            // Old on-disk pyramids had flipped y indexing and no metadata.
            return .legacyFlipped
        }
        return yIndexMode
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
        OverlayLibrary.encodeTileImageData(cgImage)
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

    /// Overzoom helper for persisted disk pyramids when MKMapView requests z > maximumZ.
    /// Walk **`parentZ`** downward from **`startParentZ`** until a parent tile exists on disk, then crop/upscale for **`path`**.
    private func overzoomedTileFromNearestDiskParent(
        path: MKTileOverlayPath,
        pyramidRoot: URL,
        startParentZ: Int
    ) -> Data? {
        let minZ = tilePyramidRuntimeInfo.map { Int($0.minimumZoom) } ?? 0
        var parentZ = startParentZ
        while parentZ >= minZ {
            let shift = path.z - parentZ
            guard shift > 0, shift < 31 else { break }
            let divisor = 1 << shift
            let parentX = path.x / divisor
            let parentY = path.y / divisor
            let childMask = divisor - 1
            let childX = path.x & childMask
            let childY = path.y & childMask
            let parentPath = MKTileOverlayPath(
                x: parentX,
                y: parentY,
                z: parentZ,
                contentScaleFactor: path.contentScaleFactor
            )
            let preferredParentPath = Self.path(parentPath, remappedFor: tilePyramidYIndexMode) ?? parentPath
            let fallbackParentPath = Self.yFlippedPath(parentPath)
            var parentCandidates = OverlayLibrary.tileCandidateFileURLs(pyramidRoot: pyramidRoot, path: preferredParentPath)
            if let fallbackParentPath {
                let fallbackCandidates = OverlayLibrary.tileCandidateFileURLs(pyramidRoot: pyramidRoot, path: fallbackParentPath)
                let existing = Set(parentCandidates.map(\.path))
                for url in fallbackCandidates where !existing.contains(url.path) {
                    parentCandidates.append(url)
                }
            }
            for parentURL in parentCandidates {
                if let parentData = try? Data(contentsOf: parentURL),
                   let overzoomed = Self.makeOverzoomedChildTileFromParentData(
                    parentTileData: parentData,
                    shift: shift,
                    childX: childX,
                    childY: childY,
                    contentScale: path.contentScaleFactor,
                    tileSize: tileSize
                   ) {
                    return overzoomed
                }
            }
            parentZ -= 1
        }
        return nil
    }

    private static func makeOverzoomedChildTileFromParentData(
        parentTileData: Data,
        shift: Int,
        childX: Int,
        childY: Int,
        contentScale: CGFloat,
        tileSize: CGSize
    ) -> Data? {
        guard shift > 0, shift < 31,
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
        ctx.interpolationQuality = .none
        ctx.clear(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let out = ctx.makeImage() else { return nil }
        return encodePNG(cgImage: out)
    }

    /// Lazy tile pyramid cache: first request renders/encodes the tile, subsequent requests hit memory or disk.
    private final class TileCache {
        private enum RasterBacking {
            /// Crop pixels from the mercator browse **`UIImage`** (already decoded).
            case bakedTexture(CGImage)
            /// Subsampled **`ImageIO`** decode + same mercator warp as **`OverlayMapBake`** — sharp zoom without holding the full bitmap.
            case sourceLOD(Data, corners: [CLLocationCoordinate2D], mercatorWidth: Int, mercatorHeight: Int)
        }

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
        private let rasterBacking: RasterBacking
        private let mapBoundingRect: MKMapRect
        private let nativeMaxZ: Int
        fileprivate var nativeMaximumZoomForOverlay: Int { nativeMaxZ }
        private let memoryCache = NSCache<NSString, NSData>()
        private let ioQueue = DispatchQueue(label: "snap-to-map.tile-cache", qos: .userInitiated)
        private let fm = FileManager.default
        private let cacheRootURL: URL

        init(
            overlayID: UUID,
            displayReferenceImage: UIImage,
            mapBoundingRect: MKMapRect,
            sourceRasterForTileLOD: Data?,
            geographicCorners: [CLLocationCoordinate2D]
        ) {
            self.overlayID = overlayID
            self.mapBoundingRect = mapBoundingRect
            let dims = Self.displayTexturePixelDimensions(displayReferenceImage)
            if let lodData = sourceRasterForTileLOD, !lodData.isEmpty, geographicCorners.count == 4 {
                self.rasterBacking = .sourceLOD(lodData, corners: geographicCorners, mercatorWidth: dims.width, mercatorHeight: dims.height)
                // Source LOD decoding can use intrinsic raster detail, so keep native max zoom
                // aligned with source metadata rather than the browse texture dimensions.
                self.nativeMaxZ = OverlayMapBake.nativeMaxZoomLevelFromSourceRaster(
                    sourceRaster: lodData,
                    mapBoundingRect: mapBoundingRect,
                    tileSizePoints: OverlayLibrary.logicalTileSizePoints,
                    screenScale: OverlayLibrary.tileDetailScreenScaleForNativeMaxZoom()
                )
            } else if let cg = displayReferenceImage.cgImage {
                self.rasterBacking = .bakedTexture(cg)
                self.nativeMaxZ = Self.computeNativeMaxZoomLevel(
                    sourceCGImage: cg,
                    mapBoundingRect: mapBoundingRect,
                    tileSizePoints: OverlayLibrary.logicalTileSizePoints,
                    screenScale: OverlayLibrary.tileDetailScreenScaleForNativeMaxZoom()
                )
            } else if let ci = CIImage(image: displayReferenceImage) {
                let extent = ci.extent.integral
                if extent.width >= 1, extent.height >= 1,
                   let decoded = BakedImageMapTileOverlay.tileDecodeCIContext.createCGImage(ci, from: extent) {
                    self.rasterBacking = .bakedTexture(decoded)
                    self.nativeMaxZ = Self.computeNativeMaxZoomLevel(
                        sourceCGImage: decoded,
                        mapBoundingRect: mapBoundingRect,
                        tileSizePoints: OverlayLibrary.logicalTileSizePoints,
                        screenScale: OverlayLibrary.tileDetailScreenScaleForNativeMaxZoom()
                    )
                } else {
                    let fallback = Self.make1x1TransparentCGImage()
                    self.rasterBacking = .bakedTexture(fallback)
                    self.nativeMaxZ = 0
                }
            } else {
                let fallback = Self.make1x1TransparentCGImage()
                self.rasterBacking = .bakedTexture(fallback)
                self.nativeMaxZ = 0
            }
            self.cacheRootURL = Self.makeCacheRootURL(
                overlayID: overlayID,
                displayReferenceImage: displayReferenceImage,
                mapBoundingRect: mapBoundingRect,
                rasterBacking: rasterBacking
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
            if shift > 0 || path.contentScaleFactor > 2.01 {
                // #region agent log
                BakedImageMapTileOverlay.agentDebugLog(
                    runId: "pre-fix",
                    hypothesisId: "H9_lazy_clamp_blur",
                    location: "OverlayMapPresentation.swift:TileCache.clampedRequest",
                    message: "lazy path clamped request",
                    data: [
                        "requestedZ": path.z,
                        "clampedZ": z,
                        "nativeMaxZ": nativeMaxZ,
                        "shift": shift,
                        "requestedX": path.x,
                        "requestedY": path.y,
                        "parentX": x,
                        "parentY": y,
                        "scale": path.contentScaleFactor,
                        "scale100": scale100,
                    ]
                )
                // #endregion
            }
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
            let data: Data?
            switch rasterBacking {
            case .bakedTexture(let cg):
                data = BakedImageMapTileOverlay.pngTileData(
                    sourceCGImage: cg,
                    tileRect: tileRect,
                    bbox: mapBoundingRect,
                    clipped: clipped,
                    tileSize: tileSize,
                    contentScale: path.contentScaleFactor
                )
            case .sourceLOD(let blob, let corners, let mw, let mh):
                data = OverlayMapBake.mercatorTileHEIFDataFromSourceRaster(
                    sourceRaster: blob,
                    corners: corners,
                    mercatorPixelWidth: mw,
                    mercatorPixelHeight: mh,
                    tileRect: tileRect,
                    bbox: mapBoundingRect,
                    clipped: clipped,
                    tileSize: tileSize,
                    contentScale: path.contentScaleFactor
                )
            }
            guard let data else {
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

        private static func displayTexturePixelDimensions(_ image: UIImage) -> (width: Int, height: Int) {
            if let cg = image.cgImage {
                return (max(1, cg.width), max(1, cg.height))
            }
            let w = Int((image.size.width * image.scale).rounded())
            let h = Int((image.size.height * image.scale).rounded())
            return (max(1, w), max(1, h))
        }

        private static func makeCacheRootURL(
            overlayID: UUID,
            displayReferenceImage: UIImage,
            mapBoundingRect: MKMapRect,
            rasterBacking: RasterBacking
        ) -> URL {
            let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let sig = cacheSignature(
                displayReferenceImage: displayReferenceImage,
                mapBoundingRect: mapBoundingRect,
                rasterBacking: rasterBacking
            )
            return cacheBase
                .appendingPathComponent("snap-to-map-tile-cache", isDirectory: true)
                .appendingPathComponent(overlayID.uuidString, isDirectory: true)
                .appendingPathComponent(sig, isDirectory: true)
        }

        private static func cacheSignature(
            displayReferenceImage: UIImage,
            mapBoundingRect: MKMapRect,
            rasterBacking: RasterBacking
        ) -> String {
            let pxW = Int((displayReferenceImage.size.width * displayReferenceImage.scale).rounded())
            let pxH = Int((displayReferenceImage.size.height * displayReferenceImage.scale).rounded())
            let modeTag: String
            switch rasterBacking {
            case .bakedTexture:
                modeTag = "baked"
            case .sourceLOD(let data, _, _, _):
                modeTag = "lod-\(data.count)"
            }
            func q(_ v: Double) -> Int64 { Int64((v * 1_000_000).rounded()) }
            return "v8-\(modeTag)-\(pxW)x\(pxH)-\(q(mapBoundingRect.origin.x))-\(q(mapBoundingRect.origin.y))-\(q(mapBoundingRect.size.width))-\(q(mapBoundingRect.size.height))"
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
            ctx.interpolationQuality = .none
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

extension BakedImageMapTileOverlay {
    /// Shared mercator tile geometry / PNG encoding for **`OverlayTilePyramidBuilder`** (same math as browse **`TileCache`**).
    static func mercatorMapRectForOfflinePyramid(path: MKTileOverlayPath, geometryFlipped: Bool) -> MKMapRect {
        mapRect(for: path, geometryFlipped: geometryFlipped)
    }

    static func mercatorTileHEIFDataForOfflinePyramid(
        sourceCGImage: CGImage,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat
    ) -> Data? {
        pngTileData(
            sourceCGImage: sourceCGImage,
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: contentScale
        )
    }

    /// Legacy name; prefer **`mercatorTileHEIFDataForOfflinePyramid`**.
    static func mercatorTilePNGDataForOfflinePyramid(
        sourceCGImage: CGImage,
        tileRect: MKMapRect,
        bbox: MKMapRect,
        clipped: MKMapRect,
        tileSize: CGSize,
        contentScale: CGFloat
    ) -> Data? {
        mercatorTileHEIFDataForOfflinePyramid(
            sourceCGImage: sourceCGImage,
            tileRect: tileRect,
            bbox: bbox,
            clipped: clipped,
            tileSize: tileSize,
            contentScale: contentScale
        )
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
        opacityBag: RasterMapOpacityBag,
        sourceRasterForTileLOD: Data?,
        geographicCorners: [CLLocationCoordinate2D],
        tilePyramidRuntime: OverlayTilePyramidRuntimeInfo? = nil,
        tilePyramidDiskRoot: URL? = nil
    ) -> OverlayMapPresentation {
        if usesTiledMapPresentation {
            return .tiled(
                BakedImageMapTileOverlay(
                    overlayID: overlayID,
                    image: mapDisplayImage,
                    mapBoundingRect: mapBoundingRect,
                    opacityBag: opacityBag,
                    sourceRasterForTileLOD: sourceRasterForTileLOD,
                    geographicCorners: geographicCorners,
                    tilePyramidDiskRoot: tilePyramidDiskRoot,
                    tilePyramidRuntime: tilePyramidRuntime
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
