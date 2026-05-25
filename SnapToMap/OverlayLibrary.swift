import CoreData
import CoreLocation
import CoreImage
import Darwin
import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let overlayTilePyramidRefinementDidComplete = Notification.Name("overlayTilePyramidRefinementDidComplete")
    /// Posted when one lazily generated tile was persisted (**`userInfo["overlayID"]`**, **`z/x/y/scale100`**).
    static let overlayProgressiveTilesDidUpdate = Notification.Name("overlayProgressiveTilesDidUpdate")
    /// Posted when an overlay's runtime work queue has fully drained (**`userInfo["overlayID"]`**).
    static let overlayProgressiveTilesQueueDidDrain = Notification.Name("overlayProgressiveTilesQueueDidDrain")
    /// Posted after post-save zoom-to-overlay animation settles (**`userInfo["overlayID"]`**).
    static let overlaySaveTransitionZoomDidSettle = Notification.Name("overlaySaveTransitionZoomDidSettle")
    /// Posted when the minZ overview tile is ready after save (**`userInfo["overlayID"]`**, **`userInfo["minZ"]`**).
    static let overlayTilePyramidMinZReady = Notification.Name("overlayTilePyramidMinZReady")
}

/// Grep Xcode console for **`[SnapMem]`** while chasing jetsam / **`EXC_RESOURCE`** spikes.
enum SnapMemoryInstrumentation {
    /// Resident size via **`task_info`** (**`mach_task_basic_info.resident_size`**), megabytes — correlates with footprint growth (not identical to jetsam “physical footprint”).
    static func checkpoint(_ label: String, file: String = #fileID, line: Int = #line) {
        let rss = residentRSSMegabytesString()
        print("[SnapMem] \(label) RSS≈\(rss) MB (\(file):\(line))")
    }

    private static func residentRSSMegabytesString() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0,
                          &count)
            }
        }
        guard rc == KERN_SUCCESS else { return "?" }
        let mb = Double(info.resident_size) / (1024 * 1024)
        return String(format: "%.1f", mb)
    }
}

/// Loads, saves, and migrates overlay data. Replaces ad-hoc `saved-overlays.json` + `overlay-images/`.
enum OverlayLibrary {
    /// Logical MapKit tile edge length in points.
    static let logicalTileSizePoints: CGFloat = 512
    static let logicalTileSize = CGSize(width: logicalTileSizePoints, height: logicalTileSizePoints)

    /// Rounds a screen/content scale to a positive integer (**1**, **2**, **3**, …).
    static func normalizedTileContentScale(_ scale: CGFloat) -> CGFloat {
        CGFloat(max(1, Int(scale.rounded())))
    }

    /// Single source of truth for tile generation: **`logicalTileSizePoints ×` device scale** (e.g. 1536 px @3×).
    static func tileContentScaleForCurrentDevice() -> CGFloat {
        normalizedTileContentScale(UIScreen.main.scale)
    }

    /// Physical output tile edge in pixels (**`logicalTileSizePoints × tileContentScale`**).
    static func physicalTileSizePixels(tileContentScale: CGFloat? = nil) -> Int {
        let scale = tileContentScale ?? tileContentScaleForCurrentDevice()
        return max(1, Int((logicalTileSizePoints * normalizedTileContentScale(scale)).rounded()))
    }

    /// Alias for **`tileContentScaleForCurrentDevice()`** — used when scheduling pyramid builds and z_max math.
    static func tileDetailScreenScaleForNativeMaxZoom() -> CGFloat {
        tileContentScaleForCurrentDevice()
    }

    /// On-disk metadata for one pyramid revision directory.
    struct TilePyramidMetadata {
        let formatVersion: Int
        let yIndexMode: String
        let tileContentScale: CGFloat
        let physicalTileSizePixels: Int
        let logicalTileSizePoints: CGFloat
        let minZ: Int?
        let maxZ: Int?
        let sourceWidth: Int?
        let sourceHeight: Int?
        let progressiveConfig: OverlayProgressiveTileConfig?
        let progressiveGeneration: Bool

        var sourceChunkSize: Int {
            progressiveConfig?.sourceChunkSize ?? OverlayProgressiveTileConfig.default.sourceChunkSize
        }
    }

    static func readTilePyramidMetadata(pyramidRoot: URL) -> TilePyramidMetadata? {
        let metaURL = pyramidRoot.appendingPathComponent("pyramid-meta.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let yIndexMode = obj["yIndexMode"] as? String else {
            return nil
        }
        let formatVersion = obj["formatVersion"] as? Int ?? 1
        let logicalPoints = (obj["logicalTileSizePoints"] as? NSNumber).map { CGFloat($0.doubleValue) }
            ?? logicalTileSizePoints
        let contentScale: CGFloat
        if let scaleNum = obj["tileContentScale"] as? NSNumber {
            contentScale = normalizedTileContentScale(CGFloat(scaleNum.doubleValue))
        } else if let physicalNum = obj["physicalTileSizePixels"] as? NSNumber, logicalPoints > 0 {
            contentScale = normalizedTileContentScale(CGFloat(physicalNum.doubleValue) / logicalPoints)
        } else {
            return nil
        }
        let physicalPx = (obj["physicalTileSizePixels"] as? NSNumber).map { $0.intValue }
            ?? physicalTileSizePixels(tileContentScale: contentScale)
        let minZ = (obj["minZ"] as? NSNumber).map { $0.intValue }
        let maxZ = (obj["maxZ"] as? NSNumber).map { $0.intValue }
        let sourceWidth = (obj["sourceWidth"] as? NSNumber).map { $0.intValue }
        let sourceHeight = (obj["sourceHeight"] as? NSNumber).map { $0.intValue }
        let progressiveGeneration = (obj["progressiveGeneration"] as? Bool) ?? (formatVersion >= 3)
        let progressiveConfig: OverlayProgressiveTileConfig? = {
            guard obj["prewarmLookaheadZooms"] != nil
                    || obj["sourceChunkSize"] != nil
                    || obj["earlyComfortDepth"] != nil else { return nil }
            return OverlayProgressiveTileConfig(
                prewarmLookaheadZooms: (obj["prewarmLookaheadZooms"] as? NSNumber)?.intValue
                    ?? OverlayProgressiveTileConfig.default.prewarmLookaheadZooms,
                earlyComfortDepth: (obj["earlyComfortDepth"] as? NSNumber)?.intValue
                    ?? OverlayProgressiveTileConfig.default.earlyComfortDepth,
                cheapLevelTileLimit: (obj["cheapLevelTileLimit"] as? NSNumber)?.intValue
                    ?? OverlayProgressiveTileConfig.default.cheapLevelTileLimit,
                prewarmMarginScreens: (obj["prewarmMarginScreens"] as? NSNumber).map { $0.doubleValue }
                    ?? OverlayProgressiveTileConfig.default.prewarmMarginScreens,
                maxConcurrentSourceChunkJobs: (obj["maxConcurrentSourceChunkJobs"] as? NSNumber)?.intValue
                    ?? OverlayProgressiveTileConfig.default.maxConcurrentSourceChunkJobs,
                maxConcurrentOutputTileJobs: (obj["maxConcurrentOutputTileJobs"] as? NSNumber)?.intValue
                    ?? OverlayProgressiveTileConfig.default.maxConcurrentOutputTileJobs,
                maxResidentSourceChunks: (obj["maxResidentSourceChunks"] as? NSNumber)?.intValue
                    ?? OverlayProgressiveTileConfig.default.maxResidentSourceChunks,
                sourceChunkSize: (obj["sourceChunkSize"] as? NSNumber)?.intValue
                    ?? OverlayProgressiveTileConfig.default.sourceChunkSize
            )
        }()
        return TilePyramidMetadata(
            formatVersion: formatVersion,
            yIndexMode: yIndexMode,
            tileContentScale: contentScale,
            physicalTileSizePixels: physicalPx,
            logicalTileSizePoints: logicalPoints,
            minZ: minZ,
            maxZ: maxZ,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            progressiveConfig: progressiveConfig,
            progressiveGeneration: progressiveGeneration
        )
    }

    static func writeTilePyramidMetadata(
        to pyramidRoot: URL,
        yIndexMode: String,
        tileContentScale: CGFloat,
        minZ: Int? = nil,
        maxZ: Int? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        progressiveConfig: OverlayProgressiveTileConfig = .default,
        progressiveGeneration: Bool = true
    ) throws {
        let scale = normalizedTileContentScale(tileContentScale)
        let physicalPx = physicalTileSizePixels(tileContentScale: scale)
        let metaURL = pyramidRoot.appendingPathComponent("pyramid-meta.json", isDirectory: false)
        var payload: [String: Any] = [
            "formatVersion": 3,
            "yIndexMode": yIndexMode,
            "logicalTileSizePoints": Double(logicalTileSizePoints),
            "tileContentScale": Double(scale),
            "physicalTileSizePixels": physicalPx,
            "progressiveGeneration": progressiveGeneration,
            "sourceChunkSize": progressiveConfig.sourceChunkSize,
            "prewarmLookaheadZooms": progressiveConfig.prewarmLookaheadZooms,
            "earlyComfortDepth": progressiveConfig.earlyComfortDepth,
            "cheapLevelTileLimit": progressiveConfig.cheapLevelTileLimit,
            "prewarmMarginScreens": progressiveConfig.prewarmMarginScreens,
            "maxConcurrentSourceChunkJobs": progressiveConfig.maxConcurrentSourceChunkJobs,
            "maxConcurrentOutputTileJobs": progressiveConfig.maxConcurrentOutputTileJobs,
            "maxResidentSourceChunks": progressiveConfig.maxResidentSourceChunks,
        ]
        if let minZ { payload["minZ"] = minZ }
        if let maxZ { payload["maxZ"] = maxZ }
        if let sourceWidth { payload["sourceWidth"] = sourceWidth }
        if let sourceHeight { payload["sourceHeight"] = sourceHeight }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metaURL, options: .atomic)
    }

    static func sourceChunkCacheDirectoryURL(pyramidRoot: URL) -> URL {
        pyramidRoot.appendingPathComponent("source-chunks", isDirectory: true)
    }

    static func sourceChunkCacheFileURL(pyramidRoot: URL, chunkX: Int, chunkY: Int) -> URL {
        sourceChunkCacheDirectoryURL(pyramidRoot: pyramidRoot)
            .appendingPathComponent("cx\(chunkX)", isDirectory: true)
            .appendingPathComponent("cy\(chunkY).heic", isDirectory: false)
    }

    private static let metadataFilename = "saved-overlays.json"
    private static let imagesDirectoryName = "overlay-images"
    private static let bakedImagesDirectoryName = "derived-baked-images"
    private static let sourceImagesDirectoryName = "persisted-source-images"
    private static let bakedTileCacheDirectoryName = "snap-to-map-tile-cache"
    private static let overlayTilePyramidsDirectoryName = "overlay-tile-pyramids"
    private static let workingImagesDirectoryName = "snap-to-map-working-images"
    /// Compared in **degrees**; avoids false “corner changed” when JSON text differs only in float formatting (which forced a **full baked re-encode + source HEIC** pass on cancel/save).
    private static let cornerEqualityEpsilonDegrees: CLLocationDegrees = 1e-7
    /// Caps baked storage footprint for standard overlays (~9.4 MP; equivalent to 3072²).
    private static let bakedPersistencePixelBudget: CGFloat = 9_437_184
    /// Baked storage budget for very large overlays (~16.8 MP; equivalent to 4096²).
    /// Runtime tile LOD restores zoom detail from source raster without persisting huge bakes.
    static let bakedPersistencePixelBudgetHighRes: CGFloat = 16_777_216
    /// Source raster size threshold that switches bake/persistence into high-res budgets.
    static let largeRasterOverlayPixelThresholdExclusive: Int64 = 20_000_000
    private static let bakedDownscaleCIContext = CIContext(options: [.highQualityDownsample: true])
    /// Base quality for smaller **source** images before megapixel scaling.
    private static let heifQualitySourceBase: CGFloat = 0.88
    /// Base quality for smaller **baked** textures before megapixel scaling.
    private static let heifQualityBakedBase: CGFloat = 0.82
    /// Floor quality for very large rasters (~400 MP class inputs).
    private static let heifQualityMinForHugeRasters: CGFloat = 0.50
    /// Pixel-count point where quality reaches `heifQualityMinForHugeRasters`.
    private static let heifQualityMinPixelThreshold: CGFloat = 250_000_000

    static func tilePyramidsBaseDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(overlayTilePyramidsDirectoryName, isDirectory: true)
    }

    static func tilePyramidRevisionDirectoryURL(id: UUID, revision: Int64) -> URL {
        tilePyramidsBaseDirectoryURL()
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("\(revision)", isDirectory: true)
    }

    static func tileDataFileURL(pyramidRoot: URL, path: MKTileOverlayPath) -> URL {
        let scale = Int((path.contentScaleFactor * 100).rounded())
        return pyramidRoot
            .appendingPathComponent("z\(path.z)", isDirectory: true)
            .appendingPathComponent("x\(path.x)", isDirectory: true)
            .appendingPathComponent("y\(path.y)@\(scale).heic", isDirectory: false)
    }

    static func tileLegacyPNGFileURL(pyramidRoot: URL, path: MKTileOverlayPath) -> URL {
        let scale = Int((path.contentScaleFactor * 100).rounded())
        return pyramidRoot
            .appendingPathComponent("z\(path.z)", isDirectory: true)
            .appendingPathComponent("x\(path.x)", isDirectory: true)
            .appendingPathComponent("y\(path.y)@\(scale).png", isDirectory: false)
    }

    static func tileCandidateFileURLs(pyramidRoot: URL, path: MKTileOverlayPath) -> [URL] {
        let preferred = tileDataFileURL(pyramidRoot: pyramidRoot, path: path)
        let legacy = tileLegacyPNGFileURL(pyramidRoot: pyramidRoot, path: path)
        guard preferred.path != legacy.path else { return [preferred] }
        return [preferred, legacy]
    }

    /// In-progress tile write path — readers must ignore **`*.part`** files.
    static func tilePartFileURL(finalURL: URL) -> URL {
        finalURL.deletingPathExtension().appendingPathExtension(finalURL.pathExtension + ".part")
    }

    /// Returns **`true`** when a persisted tile file exists and looks complete (not a partial write).
    static func isReadableTileFile(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              url.lastPathComponent.contains(".part") == false else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.intValue > 64
    }

    /// Write tile bytes atomically: temp **`*.part`** → fsync → rename into final HEIC/PNG slot.
    static func atomicWriteTileData(_ data: Data, to finalURL: URL) throws {
        let fm = FileManager.default
        let dir = finalURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let partURL = tilePartFileURL(finalURL: finalURL)
        if fm.fileExists(atPath: partURL.path) {
            try? fm.removeItem(at: partURL)
        }
        try data.write(to: partURL, options: .noFileProtection)
        if let handle = try? FileHandle(forWritingTo: partURL) {
            try handle.synchronize()
            try handle.close()
        }
        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: partURL, to: finalURL)
        guard isReadableTileFile(at: finalURL) else {
            try? fm.removeItem(at: finalURL)
            throw NSError(
                domain: "OverlayLibrary",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tile write verification failed at \(finalURL.path)"]
            )
        }
    }

    /// Debug-only helper for simulator investigations: counts persisted tile PNGs by z-level.
    /// Highest **`z`** directory on disk that contains at least one tile file (HEIC/PNG).
    static func diskMaximumZoomLevel(pyramidRoot: URL) -> Int {
        let counts = debugTilePyramidPNGCountsByZoom(pyramidRoot: pyramidRoot)
        return counts.keys.max() ?? -1
    }

    static func debugTilePyramidPNGCountsByZoom(pyramidRoot: URL) -> [Int: Int] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: pyramidRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var counts: [Int: Int] = [:]
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "png" || ext == "heic" || ext == "heif" else { continue }
            let zComponent = fileURL.pathComponents.first { $0.hasPrefix("z") } ?? ""
            guard zComponent.count > 1, let z = Int(zComponent.dropFirst()) else { continue }
            counts[z, default: 0] += 1
        }
        return counts
    }

    static func encodeTileImageData(_ cgImage: CGImage, quality: CGFloat = OverlayTileHEIFEncoding.defaultQuality) -> Data? {
        OverlayTileHEIFEncoding.encodeTileImageData(cgImage, quality: quality)
    }

    /// Fully transparent pyramid slot (MapKit viewport neighbors outside overlay bbox at minZ).
    static func transparentTileHEIFData(logicalTileSize: CGSize, contentScale: CGFloat) -> Data? {
        let pxW = max(1, Int((logicalTileSize.width * contentScale).rounded()))
        let pxH = max(1, Int((logicalTileSize.height * contentScale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: pxW,
                  height: pxH,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cg = ctx.makeImage() else { return nil }
        return OverlayTileHEIFEncoding.encodeTileImageData(cg, knownOpaque: false)
    }

    /// Disk slot if callers choose to persist an edit working raster (**HEIC**/JPEG). Prefer **`uiImageSubsampling`** directly from **`sourceRasterData`** when loading **`UIImage`** for **`CIImage`** paths unless reuse across launches matters.
    static func workingImageCacheURL(for overlayID: UUID) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(workingImagesDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(overlayID.uuidString).heic", isDirectory: false)
    }

    /// Downsample using **`CGImageSourceCreateThumbnailAtIndex`** — avoids allocating the intrinsic (**400 MP+**) bitmap.
    static func uiImageSubsampling(from data: Data, maxPixelDimension: CGFloat) -> UIImage? {
        guard maxPixelDimension >= 1 else { return nil }
        return ImageIODecodeLimiter.synchronizing {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let maxPx = Int(maxPixelDimension.rounded(.towardZero))
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPx,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
    }

    private static func removeTilePyramidFolderFromDisk(id: UUID) {
        let url = tilePyramidsBaseDirectoryURL().appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func overlayImageFilename(id: UUID) -> String {
        "\(id.uuidString).png"
    }

    private static func overlayBakedImageFilename(id: UUID) -> String {
        "\(id.uuidString)-baked.png"
    }

    /// Merges concurrent **`saveOverlays`** calls so only **one** background context runs at a time (logs showed overlapping **`persist`** / inflated **`overlayPersistenceInFlight`** and relaunch before **`count:2`** finished → **`loadedCount:1`**).
    private struct CoalescedSave {
        var overlays: [OverlayItem]
        var forceRewriteSource: Bool
        var forceRewriteBaked: Bool
        var completions: [@Sendable (Bool) -> Void]
    }

    private static let saveLock = NSLock()
    private static var saveCoalesced: CoalescedSave?
    private static var saveFlushRunning = false
    private static let refinementQueue = DispatchQueue(label: "snap-to-map.refinement-queue", qos: .utility)
    private static let pyramidSuppressionLock = NSLock()
    private static var pyramidSuppressedOverlayIDs = Set<UUID>()
    private static let pyramidBuildRevisionLock = NSLock()
    private static var activePyramidBuildRevisionByOverlayID: [UUID: Int64] = [:]

    private static let saveTransitionLock = NSLock()
    private static var saveTransitionOverlayIDs = Set<UUID>()
    private static var deferredMinZBuildJobs: [(overlayID: UUID, revision: Int64)] = []

    /// Marks an overlay entering save-after-edit; defers minZ build and disables runtime prewarm until zoom settles.
    static func beginSaveTransition(overlayID: UUID) {
        saveTransitionLock.lock()
        saveTransitionOverlayIDs.insert(overlayID)
        saveTransitionLock.unlock()
        OverlayTileRuntimeScheduler.shared.enterSaveTransition(overlayID: overlayID)
        OverlaySaveTransitionLog.stage("save.started", overlayID: overlayID)
    }

    static func isInSaveTransition(_ overlayID: UUID) -> Bool {
        saveTransitionLock.lock()
        let active = saveTransitionOverlayIDs.contains(overlayID)
        saveTransitionLock.unlock()
        return active
    }

    /// Runs deferred minZ build after Core Data persist completes and edit resources were released on main.
    static func runDeferredMinZBuildAfterSaveTransition(
        overlayID: UUID,
        container: NSPersistentContainer,
        tileContentScale: CGFloat = tileContentScaleForCurrentDevice()
    ) {
        saveTransitionLock.lock()
        let jobs = deferredMinZBuildJobs.filter { $0.overlayID == overlayID }
        deferredMinZBuildJobs.removeAll { $0.overlayID == overlayID }
        saveTransitionLock.unlock()
        guard !jobs.isEmpty else {
            OverlaySaveTransitionLog.stage("minZ.deferred.none", overlayID: overlayID)
            return
        }
        OverlaySaveTransitionLog.stage("metadata.persisted", overlayID: overlayID, extra: "jobs=\(jobs.count)")
        for job in jobs {
            scheduleMinZBuildOnly(
                overlayID: job.overlayID,
                revision: job.revision,
                container: container,
                tileContentScale: tileContentScale
            )
        }
    }

    /// Enables runtime prewarm after post-save zoom animation completes.
    static func enablePrewarmAfterSaveZoomSettled(
        overlayID: UUID,
        container: NSPersistentContainer,
        visibleMapRect: MKMapRect?,
        currentZoom: Double,
        tileContentScale: CGFloat = tileContentScaleForCurrentDevice()
    ) {
        saveTransitionLock.lock()
        saveTransitionOverlayIDs.remove(overlayID)
        saveTransitionLock.unlock()
        OverlaySaveTransitionLog.stage("prewarm.enabling", overlayID: overlayID)
        refinementQueue.async {
            container.performBackgroundTask { context in
                let fr = StoredMapOverlay.fetchRequest()
                fr.fetchLimit = 1
                fr.predicate = NSPredicate(format: "uuid == %@", overlayID as CVarArg)
                guard let row = try? context.fetch(fr).first,
                      let source = persistedSourceImageData(row: row, overlayID: overlayID),
                      let corners = decodeCorners(from: row.cornersJSON ?? ""),
                      corners.count == 4,
                      let bakedBlob = bakedImageDataFromDisk(id: overlayID),
                      let bakedImg = UIImage(data: bakedBlob) else { return }
                OverlayTileRuntimeScheduler.shared.startProgressiveRuntime(
                    overlayID: overlayID,
                    revision: row.tilePyramidRevision,
                    corners: corners,
                    sourceRaster: source,
                    bakedFallback: bakedImg,
                    tileContentScale: tileContentScale,
                    visibleMapRect: visibleMapRect,
                    currentZoom: currentZoom,
                    enablePrewarm: true,
                    saveTransitionRecovery: true
                )
                OverlaySaveTransitionLog.stage("prewarm.enabled", overlayID: overlayID)
            }
        }
    }

    /// While **`true`**, background pyramid preview/refinement for this overlay is skipped (edit mode must not compete with tile builds).
    static func setPyramidBuildSuppressed(_ overlayID: UUID, suppressed: Bool) {
        pyramidSuppressionLock.lock()
        if suppressed {
            pyramidSuppressedOverlayIDs.insert(overlayID)
        } else {
            pyramidSuppressedOverlayIDs.remove(overlayID)
        }
        pyramidSuppressionLock.unlock()
    }

    static func isPyramidBuildSuppressed(_ overlayID: UUID) -> Bool {
        pyramidSuppressionLock.lock()
        let suppressed = pyramidSuppressedOverlayIDs.contains(overlayID)
        pyramidSuppressionLock.unlock()
        return suppressed
    }

    /// Registers the revision background pyramid work should target; stale in-flight builds observe a mismatch and exit early.
    static func noteActivePyramidBuildRevision(_ overlayID: UUID, revision: Int64) {
        pyramidBuildRevisionLock.lock()
        activePyramidBuildRevisionByOverlayID[overlayID] = revision
        pyramidBuildRevisionLock.unlock()
    }

    static func isCurrentPyramidBuildRevision(_ overlayID: UUID, revision: Int64) -> Bool {
        pyramidBuildRevisionLock.lock()
        defer { pyramidBuildRevisionLock.unlock() }
        guard let active = activePyramidBuildRevisionByOverlayID[overlayID] else { return true }
        return active == revision
    }

    private enum OverlayEncodeError: Error {
        case heicSourceEncodeFailed
        case heicBakedEncodeFailed
    }

    // MARK: - Public API

    /// Decoded-image alpha check guards against legacy opaque baked blobs (e.g. old JPEG rows).
    private static func bakedImageLikelyPreservesAlpha(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        switch cg.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    /// Fills **`bbox*`** / **`hasBoundingBox`** from **`cornersJSON`** for rows that predate spatial metadata. Safe to call repeatedly.
    static func migrateOverlayBoundingBoxesIfNeeded(context: NSManagedObjectContext) throws {
        let fr = StoredMapOverlay.fetchRequest()
        fr.predicate = NSPredicate(format: "hasBoundingBox == NO")
        let rows = try context.fetch(fr)
        for row in rows {
            guard let corners = decodeCorners(from: row.cornersJSON ?? ""), corners.count == 4 else { continue }
            assignGeorectMetadata(to: row, corners: corners)
        }
        if context.hasChanges {
            try context.save()
        }
    }

    /// Maintenance utility: removes all baked-derived disk data (and optionally tile-cache files) so imagery is regenerated from source data.
    @discardableResult
    static func clearAllBakedDerivedData(context: NSManagedObjectContext, clearTileCache: Bool = false) throws -> Int {
        clearAllBakedImagesFromDisk()
        if clearTileCache {
            clearBakedTileCacheFromDisk()
            clearPersistedTilePyramidsFromDisk()
        }
        return 0
    }

    static func clearBakedTileCacheFromDisk() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        guard let root = caches.first?.appendingPathComponent(bakedTileCacheDirectoryName, isDirectory: true) else { return }
        guard fm.fileExists(atPath: root.path) else { return }
        try? fm.removeItem(at: root)
    }

    private static func clearPersistedTilePyramidsFromDisk() {
        let root = tilePyramidsBaseDirectoryURL()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    static func clearAllBakedImagesFromDisk() {
        let fm = FileManager.default
        let root = bakedImagesDirectoryURL()
        guard fm.fileExists(atPath: root.path) else { return }
        try? fm.removeItem(at: root)
    }

    /// Shared with **`loadOverlays`** and launch resume — **`nil`** when the row is heavy but has no usable on-disk pyramid.
    private static func tilePyramidRuntimeInfo(from row: StoredMapOverlay, overlayID: UUID) -> OverlayTilePyramidRuntimeInfo? {
        let rev = row.tilePyramidRevision
        guard rev > 0,
              row.tileMinimumZoom >= 0,
              row.tileMaximumZoom >= row.tileMinimumZoom else { return nil }
        let disk = tilePyramidRevisionDirectoryURL(id: overlayID, revision: rev)
        guard FileManager.default.fileExists(atPath: disk.path) else { return nil }
        let previewMax = row.tileMaximumZoomPreview >= 0 ? row.tileMaximumZoomPreview : row.tileMaximumZoom
        let fullMax = row.tileMaximumZoomFull >= 0 ? row.tileMaximumZoomFull : row.tileMaximumZoom
        return OverlayTilePyramidRuntimeInfo(
            revision: rev,
            minimumZoom: row.tileMinimumZoom,
            maximumZoom: row.tileMaximumZoom,
            previewMaximumZoom: previewMax,
            fullMaximumZoom: fullMax,
            refinementInProgress: row.tileRefinementInProgress
        )
    }

    private static func rowMissingTilePyramidRuntime(row: StoredMapOverlay, overlayID: UUID, sourcePixels: Int64) -> Bool {
        guard sourcePixels > largeRasterOverlayPixelThresholdExclusive else { return false }
        return tilePyramidRuntimeInfo(from: row, overlayID: overlayID) == nil
    }

    private static func missingTilePyramidRuntimeReason(row: StoredMapOverlay, overlayID: UUID, sourcePixels: Int64) -> String {
        guard sourcePixels > largeRasterOverlayPixelThresholdExclusive else { return "notHeavy" }
        if row.tilePyramidRevision <= 0 { return "neverStartedRev0" }
        if row.tileMinimumZoom < 0 || row.tileMaximumZoom < row.tileMinimumZoom { return "metadataPlaceholder" }
        let disk = tilePyramidRevisionDirectoryURL(id: overlayID, revision: row.tilePyramidRevision)
        if !FileManager.default.fileExists(atPath: disk.path) { return "diskMissing" }
        return "unknown"
    }

    /// Loads overlay rows. Pass **`intersectingMapRect`** to fetch only rows whose stored bounds overlap the map viewport (skips loading off-screen blobs from SQLite where possible).
    static func loadOverlays(
        viewContext: NSManagedObjectContext,
        intersectingMapRect: MKMapRect? = nil,
        mapRectPaddingFraction: Double = 0.12
    ) throws -> [OverlayItem] {
        let request = StoredMapOverlay.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredMapOverlay.sortOrder, ascending: true)]
        if let rect = intersectingMapRect {
            let v = mapRectExpandedForSpatialQuery(rect, paddingFraction: mapRectPaddingFraction)
            request.predicate = NSPredicate(
                format: "hasBoundingBox == YES AND bboxMinX < %@ AND %@ < bboxMaxX AND bboxMinY < %@ AND %@ < bboxMaxY",
                NSNumber(value: v.maxX),
                NSNumber(value: v.origin.x),
                NSNumber(value: v.maxY),
                NSNumber(value: v.origin.y)
            )
        }
        let rows = try viewContext.fetch(request)
        var result: [OverlayItem] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let uuid = row.uuid,
                  let corners = decodeCorners(from: row.cornersJSON ?? ""),
                  corners.count == 4,
                  hasPersistedSource(row: row, overlayID: uuid) else {
                continue
            }
            let inlineSource = row.sourceImageData
            let fileBackedSource = sourceImageExistsOnDisk(id: uuid)
            let sourcePixels: Int64 = {
                if let cached = inlineSource.flatMap({ UIImage.rasterPixelCount(forCompressedImageData: $0) }) {
                    return cached
                }
                if fileBackedSource,
                   let mapped = sourceImageDataFromDisk(id: uuid),
                   let px = UIImage.rasterPixelCount(forCompressedImageData: mapped) {
                    return px
                }
                return Int64.max
            }()
            let isHeavy = sourcePixels > largeRasterOverlayPixelThresholdExclusive
            let sourceDataForItem: Data? = {
                if isHeavy, fileBackedSource { return nil }
                if let inlineSource, !inlineSource.isEmpty { return inlineSource }
                return sourceImageDataFromDisk(id: uuid)
            }()

            let sourceImage: UIImage
            if isHeavy {
                sourceImage = OverlayItem.browseSourceMemoryPlaceholder()
            } else {
                guard let sourceData = sourceDataForItem, let decoded = UIImage(data: sourceData) else { continue }
                sourceImage = decoded
            }

            let placement = decodePlacementCamera(from: row.placementCameraJSON)
            /// Reject only legacy undersized bakes (pre–high-res persist cap). Current tiled overlays persist ~16 MP bakes by design.
            let minAcceptableBakedPixelCount = bakedPersistencePixelBudgetHighRes * 0.85
            let mapDisplay: UIImage
            if isHeavy {
                let bakedOK: UIImage? = {
                    guard let baked = bakedImageDataFromDisk(id: uuid),
                          let img = UIImage(data: baked),
                          bakedImageLikelyPreservesAlpha(img) else { return nil }
                    let bakedPixels = (img.size.width * img.scale) * (img.size.height * img.scale)
                    return bakedPixels >= minAcceptableBakedPixelCount ? img : nil
                }()
                if let bakedOK {
                    mapDisplay = bakedOK
                } else if let diskBytes = fileBackedSource ? sourceImageDataFromDisk(id: uuid) : sourceDataForItem,
                          let full = UIImage(data: diskBytes) {
                    mapDisplay = OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: full, corners: corners) ?? full
                } else {
                    continue
                }
            } else if let baked = bakedImageDataFromDisk(id: uuid),
                      let img = UIImage(data: baked),
                      bakedImageLikelyPreservesAlpha(img) {
                mapDisplay = img
            } else {
                mapDisplay = OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: sourceImage, corners: corners) ?? sourceImage
            }
            let tilePyramidRuntime: OverlayTilePyramidRuntimeInfo? = {
                guard isHeavy else { return nil }
                return tilePyramidRuntimeInfo(from: row, overlayID: uuid)
            }()
            if isHeavy {
                let runtimeLabel: String
                if let runtime = tilePyramidRuntime {
                    let root = tilePyramidRevisionDirectoryURL(id: uuid, revision: runtime.revision)
                    let counts = debugTilePyramidPNGCountsByZoom(pyramidRoot: root)
                    let levels = counts.keys.sorted().map { "z\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
                    runtimeLabel = "rev=\(runtime.revision) minZ=\(runtime.minimumZoom) maxZ=\(runtime.maximumZoom) previewMax=\(runtime.previewMaximumZoom) fullMax=\(runtime.fullMaximumZoom) refining=\(runtime.refinementInProgress) rootExists=\(FileManager.default.fileExists(atPath: root.path)) levels=[\(levels)]"
                } else {
                    let reason = missingTilePyramidRuntimeReason(row: row, overlayID: uuid, sourcePixels: sourcePixels)
                    runtimeLabel = "missing runtime (rowRev=\(row.tilePyramidRevision) rowMinZ=\(row.tileMinimumZoom) rowMaxZ=\(row.tileMaximumZoom) reason=\(reason))"
                }
                print("[TileDiag] load.row id=\(uuid.uuidString.prefix(8)) heavy=true \(runtimeLabel)")
            }
            result.append(
                OverlayItem(
                    id: uuid,
                    sourceImage: sourceImage,
                    mapDisplayImage: mapDisplay,
                    corners: corners,
                    placementCamera: placement,
                    preservedSourceFileData: nil,
                    sourceImagePreWrittenToDisk: fileBackedSource,
                    cachedSourceRasterPixels: fileBackedSource ? sourcePixels : nil,
                    sourceRasterData: sourceDataForItem,
                    tilePyramid: tilePyramidRuntime
                )
            )
        }
        return result
    }

    /// Persists on a **private** Core Data queue via **`performBackgroundTask`**. Encoding is **sequential** (**ImageIO** HEIC + **`CGImage`**) so work stays off the main thread without crossing **`UIImage`** from concurrent worker pools.
    static func saveOverlays(
        _ overlays: [OverlayItem],
        in container: NSPersistentContainer,
        forceRewriteSource: Bool = false,
        forceRewriteBaked: Bool = false,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        saveLock.lock()
        if var c = saveCoalesced {
            c.overlays = overlays
            c.forceRewriteSource = c.forceRewriteSource || forceRewriteSource
            c.forceRewriteBaked = c.forceRewriteBaked || forceRewriteBaked
            if let completion { c.completions.append(completion) }
            saveCoalesced = c
        } else {
            saveCoalesced = CoalescedSave(
                overlays: overlays,
                forceRewriteSource: forceRewriteSource,
                forceRewriteBaked: forceRewriteBaked,
                completions: completion.map { [$0] } ?? []
            )
        }
        let startFlush = !saveFlushRunning
        if startFlush { saveFlushRunning = true }
        saveLock.unlock()
        if startFlush {
            flushSaveCoalescedQueue(container: container)
        }
    }

    /// On app restart, log every persisted source's pixel dimensions (threshold / tiled-path audit).
    static func logPersistedSourceRasterPixelCounts(
        in container: NSPersistentContainer,
        completion: (@Sendable () -> Void)? = nil
    ) {
        container.performBackgroundTask { context in
            let request = StoredMapOverlay.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredMapOverlay.sortOrder, ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            let threshold = largeRasterOverlayPixelThresholdExclusive
            print(
                "[TileDiag] persistedSourceAudit begin count=\(rows.count) thresholdExclusive=\(threshold) (sources with count > \(threshold) use MKTileOverlay / tiled path)"
            )
            for (index, row) in rows.enumerated() {
                let idLabel = row.uuid.map { String($0.uuidString.prefix(8)) } ?? "nil-uuid"
                guard let id = row.uuid else {
                    print("[TileDiag] persistedSourceAudit[\(index)] id=nil sortOrder=\(row.sortOrder) skipped=missingUUID")
                    continue
                }
                guard hasPersistedSource(row: row, overlayID: id) else {
                    print("[TileDiag] persistedSourceAudit[\(index)] id=\(idLabel) sortOrder=\(row.sortOrder) skipped=missingSource onDisk=\(row.sourceImageOnDisk)")
                    continue
                }
                guard let sourceData = persistedSourceImageData(row: row, overlayID: id) else {
                    print("[TileDiag] persistedSourceAudit[\(index)] id=\(idLabel) sortOrder=\(row.sortOrder) skipped=missingSourceBytes onDisk=\(row.sourceImageOnDisk)")
                    continue
                }
                guard let sourcePixels = UIImage.logRasterPixelCount(forCompressedImageData: sourceData) else {
                    print(
                        "[TileDiag] persistedSourceAudit[\(index)] id=\(idLabel) sortOrder=\(row.sortOrder) skipped=metadataUnreadable bytes=\(sourceData.count)"
                    )
                    continue
                }
                let isHeavy = sourcePixels > threshold
                let hasRuntime = tilePyramidRuntimeInfo(from: row, overlayID: id) != nil
                let needsPyramid = rowMissingTilePyramidRuntime(row: row, overlayID: id, sourcePixels: sourcePixels)
                let presentation: String = {
                    guard isHeavy else { return "ImageRasterMapOverlay" }
                    if hasRuntime { return "MKTileOverlay(runtimeOK)" }
                    return "MKTileOverlay(expected,missingPyramid)"
                }()
                let migrationNote: String = {
                    guard isHeavy, row.tilePyramidRevision <= 0 else { return "" }
                    return " thresholdMigrationCandidate"
                }()
                print(
                    "[TileDiag] persistedSourceAudit[\(index)] id=\(idLabel) sortOrder=\(row.sortOrder) heavy=\(isHeavy) presentation=\(presentation)\(migrationNote) needsInitialPyramid=\(needsPyramid) rowRev=\(row.tilePyramidRevision) rowMinZ=\(row.tileMinimumZoom) rowMaxZ=\(row.tileMaximumZoom) refining=\(row.tileRefinementInProgress)"
                )
            }
            print("[TileDiag] persistedSourceAudit end")
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// On app restart, continue any interrupted refinement jobs where possible and clear stale flags
    /// when the row is already complete or required assets are missing.
    static func resumePendingRefinements(
        in container: NSPersistentContainer,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let tileContentScale = tileContentScaleForCurrentDevice()
        container.performBackgroundTask { context in
            let fr = StoredMapOverlay.fetchRequest()
            fr.predicate = NSPredicate(format: "tileRefinementInProgress == YES")
            let rows = (try? context.fetch(fr)) ?? []
            var jobs: [(id: UUID, revision: Int64)] = []
            for row in rows {
                guard let id = row.uuid else {
                    row.tileRefinementInProgress = false
                    continue
                }
                let hasValidRange = row.tileMaximumZoomFull > row.tileMaximumZoom
                let hasRevision = row.tilePyramidRevision > 0
                let hasSource = hasPersistedSource(row: row, overlayID: id)
                let hasCorners = decodeCorners(from: row.cornersJSON ?? "")?.count == 4
                let hasBaked = bakedImageDataFromDisk(id: id) != nil
                if hasValidRange, hasRevision, hasSource, hasCorners, hasBaked {
                    jobs.append((id: id, revision: row.tilePyramidRevision))
                } else {
                    print(
                        "[TileDiag] resume.refineClear id=\(id.uuidString.prefix(8)) rev=\(row.tilePyramidRevision) hasValidRange=\(hasValidRange) hasRevision=\(hasRevision) hasSource=\(hasSource) hasCorners=\(hasCorners) hasBaked=\(hasBaked)"
                    )
                    row.tileRefinementInProgress = false
                }
            }
            if context.hasChanges {
                try? context.save()
            }
            if !jobs.isEmpty {
                print("[TileDiag] resume.refineScheduled count=\(jobs.count) ids=\(jobs.map { $0.id.uuidString.prefix(8) }.joined(separator: ","))")
                scheduleBackgroundRefinement(
                    jobs: jobs,
                    container: container,
                    tileContentScale: tileContentScale
                )
            }
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// Heavy overlays whose Core Data / on-disk pyramid state would leave **`OverlayItem.tilePyramid == nil`** at load — schedule an initial build on relaunch (e.g. **`rowRev == 0`** after an interrupted first save).
    static func resumeMissingInitialPyramidBuilds(
        in container: NSPersistentContainer,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let tileContentScale = tileContentScaleForCurrentDevice()
        container.performBackgroundTask { context in
            let rows = (try? context.fetch(StoredMapOverlay.fetchRequest())) ?? []
            var pyramidJobs: [UUID: Int64] = [:]
            for row in rows {
                guard let id = row.uuid,
                      let source = persistedSourceImageData(row: row, overlayID: id),
                      let corners = decodeCorners(from: row.cornersJSON ?? ""),
                      corners.count == 4,
                      bakedImageDataFromDisk(id: id) != nil else { continue }
                let sourcePixels = UIImage.rasterPixelCount(forCompressedImageData: source) ?? 0
                guard rowMissingTilePyramidRuntime(row: row, overlayID: id, sourcePixels: sourcePixels) else { continue }

                let reason = missingTilePyramidRuntimeReason(row: row, overlayID: id, sourcePixels: sourcePixels)
                if row.tilePyramidRevision <= 0 {
                    row.tilePyramidRevision = 1
                    removeTilePyramidFolderFromDisk(id: id)
                } else if row.tileMinimumZoom >= 0 {
                    removeTilePyramidFolderFromDisk(id: id)
                    row.tileMinimumZoom = -1
                    row.tileMaximumZoom = -1
                    row.tileMaximumZoomPreview = -1
                    row.tileMaximumZoomFull = -1
                }
                row.tileRefinementInProgress = true
                noteActivePyramidBuildRevision(id, revision: row.tilePyramidRevision)
                pyramidJobs[id] = row.tilePyramidRevision
                print(
                    "[TileDiag] resume.initialPyramid id=\(id.uuidString.prefix(8)) rev=\(row.tilePyramidRevision) sourcePx=\(sourcePixels) reason=\(reason)"
                )
            }
            if context.hasChanges {
                try? context.save()
            }
            if !pyramidJobs.isEmpty {
                print("[TileDiag] resume.initialPyramidScheduled count=\(pyramidJobs.count)")
                scheduleBackgroundPyramidBuild(
                    pyramidJobsByOverlayID: pyramidJobs,
                    container: container,
                    tileContentScale: tileContentScale
                )
            } else {
                print("[TileDiag] resume.initialPyramidScheduled count=0")
            }
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    private static func flushSaveCoalescedQueue(container: NSPersistentContainer) {
        saveLock.lock()
        guard let batch = saveCoalesced else {
            saveFlushRunning = false
            saveLock.unlock()
            return
        }
        saveCoalesced = nil
        saveLock.unlock()

        let snapshot = batch.overlays
        let forceS = batch.forceRewriteSource
        let forceB = batch.forceRewriteBaked
        let batchCompletions = batch.completions
        let tileContentScale = tileContentScaleForCurrentDevice()

        container.performBackgroundTask { context in
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            var success = false
            defer {
                DispatchQueue.main.async {
                    for cb in batchCompletions {
                        cb(success)
                    }
                    flushSaveCoalescedQueue(container: container)
                }
            }
            do {
                SnapMemoryInstrumentation.checkpoint("persist.bg.beforePersist overlayCount=\(snapshot.count)")
                let pyramidJobs = try persist(overlays: snapshot, context: context, forceRewriteSource: forceS, forceRewriteBaked: forceB)
                SnapMemoryInstrumentation.checkpoint("persist.bg.beforeContextSave pyramidJobKeys=\(pyramidJobs.count)")
                try context.save()
                success = true
                context.reset()
                SnapMemoryInstrumentation.checkpoint("persist.bg.afterContextSave pyramidJobKeys=\(pyramidJobs.count)")

                if !pyramidJobs.isEmpty {
                    saveTransitionLock.lock()
                    let deferred = pyramidJobs.filter { saveTransitionOverlayIDs.contains($0.key) }
                    let immediate = pyramidJobs.filter { !saveTransitionOverlayIDs.contains($0.key) }
                    for (overlayID, revision) in deferred {
                        deferredMinZBuildJobs.append((overlayID: overlayID, revision: revision))
                        OverlaySaveTransitionLog.stage(
                            "metadata.persisted.deferredMinZ",
                            overlayID: overlayID,
                            extra: "rev=\(revision)"
                        )
                    }
                    saveTransitionLock.unlock()
                    if !immediate.isEmpty {
                        scheduleBackgroundPyramidBuild(
                            pyramidJobsByOverlayID: Dictionary(uniqueKeysWithValues: immediate.map { ($0.key, $0.value) }),
                            container: container,
                            tileContentScale: tileContentScale
                        )
                    }
                }
            } catch {
                #if DEBUG
                print("OverlayLibrary save failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Private

    /// Encodes a mercator bake for disk persistence (call off main during save draft to avoid peak RSS in **`persist`**).
    static func encodeBakedImageForPersist(_ image: UIImage) throws -> Data {
        try encodeBakedImage(image)
    }

    /// Writes source bytes to Application Support during save draft; **`persist`** sets metadata only (no Core Data blob).
    static func persistSourceImageToDiskDuringSaveDraft(_ data: Data, overlayID: UUID) -> Bool {
        guard !data.isEmpty else { return false }
        return (try? autoreleasepool {
            try writeSourceImageDataToDisk(data, id: overlayID)
            return sourceImageExistsOnDisk(id: overlayID)
        }) ?? false
    }

    /// Heavy overlays: memory-mapped source bytes from Application Support (fallback when **`OverlayItem.sourceRasterData`** is nil).
    static func persistedSourceRasterData(overlayID: UUID) -> Data? {
        guard sourceImageExistsOnDisk(id: overlayID) else { return nil }
        return sourceImageDataFromDisk(id: overlayID)
    }

    private static func hasPersistedSource(row: StoredMapOverlay, overlayID: UUID) -> Bool {
        if sourceImageExistsOnDisk(id: overlayID) { return true }
        if let data = row.sourceImageData, !data.isEmpty { return true }
        return false
    }

    private static func persistedSourceImageData(row: StoredMapOverlay, overlayID: UUID) -> Data? {
        if row.sourceImageOnDisk, let disk = sourceImageDataFromDisk(id: overlayID) {
            return disk
        }
        if let inline = row.sourceImageData, !inline.isEmpty {
            return inline
        }
        return sourceImageDataFromDisk(id: overlayID)
    }

    private static func persistSourceImage(for overlay: OverlayItem, to row: StoredMapOverlay) throws {
        let id = overlay.id
            if overlay.sourceImagePreWrittenToDisk, sourceImageExistsOnDisk(id: id) {
                row.sourceImageOnDisk = true
                row.sourceImageData = nil
                print("[TileDiag] persist.sourceFileBacked id=\(id.uuidString.prefix(8)) preWritten=true")
                return
            }

            if sourceImageExistsOnDisk(id: id), overlay.sourceRasterData == nil, overlay.cachedSourceRasterPixels != nil {
                row.sourceImageOnDisk = true
                row.sourceImageData = nil
                print("[TileDiag] persist.sourceFileBacked id=\(id.uuidString.prefix(8)) existingDisk=true")
                return
            }

        let bytes: Data
        if let preserved = overlay.preservedSourceFileData {
            bytes = preserved
        } else if let rd = overlay.sourceRasterData, !rd.isEmpty {
            bytes = rd
        } else {
            bytes = try autoreleasepool {
                try Self.encodeSourceImage(overlay.sourceImage)
            }
        }

        let pixelCount = overlay.cachedSourceRasterPixels
            ?? UIImage.rasterPixelCount(forCompressedImageData: bytes)
            ?? 0
        let fileBacked = pixelCount > largeRasterOverlayPixelThresholdExclusive

        if fileBacked {
            try writeSourceImageDataToDisk(bytes, id: id)
            row.sourceImageOnDisk = true
            row.sourceImageData = nil
            print("[TileDiag] persist.sourceFileBacked id=\(id.uuidString.prefix(8)) bytes=\(bytes.count)")
        } else {
            row.sourceImageOnDisk = false
            row.sourceImageData = bytes
        }
    }

    /// Bake + encode + disk write on a background thread during save draft; returns **`true`** when readable on disk.
    static func persistBakedImageToDiskDuringSaveDraft(_ image: UIImage, overlayID: UUID) -> Bool {
        (try? autoreleasepool {
            let data = try encodeBakedImageForPersist(image)
            writeBakedImageDataToDisk(data, id: overlayID)
            return bakedImageExistsOnDisk(id: overlayID)
        }) ?? false
    }

    /// Always writes source rows as **HEIC**.
    private static func bakedBlobForPersist(from overlay: OverlayItem) throws -> Data {
        return try autoreleasepool {
            try Self.encodeBakedImage(overlay.mapDisplayImage)
        }
    }

    private static func encodeSourceImage(_ image: UIImage) throws -> Data {
        let q = heifQualityForMegapixels(of: image, baseQuality: heifQualitySourceBase)
        // Source photos are typically opaque; encode without alpha to reduce decode RAM and file size.
        guard let heic = BakedHEIFEncoder.encodeLossy(image: image, quality: q, preserveAlpha: false) else {
            throw OverlayEncodeError.heicSourceEncodeFailed
        }
        return heic
    }

    /// Mercator bake keeps **transparency** outside the warped quad and is always persisted as **HEIC**.
    private static func encodeBakedImage(_ image: UIImage) throws -> Data {
        let forDisk = imageScaledForBakedPersistence(image)
        let q = heifQualityForMegapixels(of: forDisk, baseQuality: heifQualityBakedBase)
        let preserveAlpha = bakedImageContainsAnyTransparency(forDisk)
        guard let heic = BakedHEIFEncoder.encodeLossy(image: forDisk, quality: q, preserveAlpha: preserveAlpha) else {
            throw OverlayEncodeError.heicBakedEncodeFailed
        }
        return heic
    }

    /// Returns `true` when at least one pixel has alpha < 255.
    /// This avoids encoding opaque bakes with an alpha channel, which increases decode memory.
    private static func bakedImageContainsAnyTransparency(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }
        guard let providerData = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(providerData) else {
            return true
        }
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        guard bytesPerPixel >= 4 else { return true }
        let alphaOffset: Int
        switch cg.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst:
            alphaOffset = 0
        case .last, .premultipliedLast, .noneSkipLast:
            alphaOffset = bytesPerPixel - 1
        default:
            return true
        }
        let stride = cg.bytesPerRow
        for y in 0..<cg.height {
            let row = ptr.advanced(by: y * stride)
            for x in 0..<cg.width {
                if row[x * bytesPerPixel + alphaOffset] < 255 {
                    return true
                }
            }
        }
        return false
    }

    /// Progressive compression by raster size: keep high quality for small/medium assets and reduce toward 0.5 for very large inputs.
    private static func heifQualityForMegapixels(of image: UIImage, baseQuality: CGFloat) -> CGFloat {
        let pxW = max(1, image.size.width * image.scale)
        let pxH = max(1, image.size.height * image.scale)
        let megapixels = (pxW * pxH) / 1_000_000
        let minQ = heifQualityMinForHugeRasters
        let startMP: CGFloat = 12
        let endMP = max(startMP + 1, heifQualityMinPixelThreshold / 1_000_000)
        if megapixels <= startMP { return baseQuality }
        if megapixels >= endMP { return minQ }
        let t = (megapixels - startMP) / (endMP - startMP)
        return baseQuality - (baseQuality - minQ) * t
    }

    private static func imageScaledForBakedPersistence(_ image: UIImage) -> UIImage {
        let pixelBudget = image.rasterExceedsLargeOverlayPixelThreshold
            ? bakedPersistencePixelBudgetHighRes
            : bakedPersistencePixelBudget
        let pxW = image.size.width * image.scale
        let pxH = image.size.height * image.scale
        let pixels = pxW * pxH
        guard pixels > pixelBudget, pixels > 0, let ci = CIImage(image: image) else { return image }
        let s = sqrt(pixelBudget / pixels)
        let outW = max(1, floor(pxW * s))
        let outH = max(1, floor(pxH * s))
        let scaleX = outW / pxW
        let scaleY = outH / pxH
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let rect = scaled.extent.integral
        guard rect.width >= 1, rect.height >= 1,
              let cg = bakedDownscaleCIContext.createCGImage(scaled, from: rect) else { return image }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    private static func cornersGeometricallyChanged(storedJSON: String?, newCorners: [CLLocationCoordinate2D]) -> Bool {
        guard newCorners.count == 4 else { return true }
        guard let stored = decodeCorners(from: storedJSON ?? ""), stored.count == 4 else { return true }
        let ε = cornerEqualityEpsilonDegrees
        for i in 0..<4 {
            if abs(stored[i].latitude - newCorners[i].latitude) > ε || abs(stored[i].longitude - newCorners[i].longitude) > ε {
                return true
            }
        }
        return false
    }

    private static func placementGeometricallyChanged(storedJSON: String?, newJSON: String?) -> Bool {
        let newCam = newJSON.flatMap { decodePlacementCamera(from: $0) }
        let oldCam = storedJSON.flatMap { decodePlacementCamera(from: $0) }
        switch (oldCam, newCam) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (old?, new?):
            let ε = 1e-7
            if abs(old.centerLatitude - new.centerLatitude) > ε || abs(old.centerLongitude - new.centerLongitude) > ε { return true }
            if abs(old.heading - new.heading) > ε { return true }
            if abs(old.centerCoordinateDistance - new.centerCoordinateDistance) > max(ε, 1e-4) { return true }
            if abs(old.pitch - new.pitch) > ε { return true }
            return false
        }
    }

    private static func persist(
        overlays: [OverlayItem],
        context: NSManagedObjectContext,
        forceRewriteSource: Bool,
        forceRewriteBaked: Bool
    ) throws -> [UUID: Int64] {
        var pyramidRebuildJobs: [UUID: Int64] = [:]
        let request = StoredMapOverlay.fetchRequest()
        let existing = try context.fetch(request)
        var byId = Dictionary(uniqueKeysWithValues: existing.compactMap { row -> (UUID, StoredMapOverlay)? in
            guard let id = row.uuid else { return nil }
            return (id, row)
        })
        let active = Set(overlays.map(\.id))
        for row in existing {
            guard let id = row.uuid, !active.contains(id) else { continue }
            removeBakedImageFromDisk(id: id)
            removeSourceImageFromDisk(id: id)
            removeTilePyramidFolderFromDisk(id: id)
            context.delete(row)
            byId.removeValue(forKey: id)
        }

        let now = Date()
        for (index, o) in overlays.enumerated() {
            try autoreleasepool {
            let coords = o.corners.map { PersistedCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            let cornersJSON = try encodeCornersJSON(coords)
            let placementJSON = try encodePlacementCamera(o.placementCamera)

            let row = byId[o.id] ?? StoredMapOverlay(context: context)
            row.uuid = o.id
            row.schemaVersion = 2
            row.sortOrder = Int32(index)

            let cornersChanged = cornersGeometricallyChanged(storedJSON: row.cornersJSON, newCorners: o.corners)
            let placementChanged = placementGeometricallyChanged(storedJSON: row.placementCameraJSON, newJSON: placementJSON)

            row.cornersJSON = cornersJSON
            assignGeorectMetadata(to: row, corners: o.corners)
            if placementChanged {
                row.placementCameraJSON = placementJSON
            }

            if row.createdAt == nil {
                row.createdAt = now
            }
            row.modifiedAt = now

            // Source bytes only when missing or forced — **not** when only corners/camera change (_pixels unchanged).
            // Baked mercator texture depends on **quad corners** only; **`placementCamera`** is map framing metadata and must not force a baked HEIC re-encode (that was making “cancel” / placement-only saves as slow as a full bake).
            let needsSourceWrite = forceRewriteSource || !hasPersistedSource(row: row, overlayID: o.id)
            let bakedContentChanged = forceRewriteBaked || cornersChanged || !bakedImageExistsOnDisk(id: o.id)
            let needsBakedWrite = bakedContentChanged && !o.bakedImagePreWrittenToDisk

            let bakedBlob: Data?
            switch (needsSourceWrite, needsBakedWrite) {
            case (true, true):
                try persistSourceImage(for: o, to: row)
                bakedBlob = try bakedBlobForPersist(from: o)
            case (true, false):
                try persistSourceImage(for: o, to: row)
                bakedBlob = nil
            case (false, true):
                bakedBlob = try bakedBlobForPersist(from: o)
            case (false, false):
                bakedBlob = nil
            }

            if let bakedBlob {
                writeBakedImageDataToDisk(bakedBlob, id: o.id)
            }

            let heavyTiled = o.usesTiledMapPresentation
            if bakedContentChanged && heavyTiled {
                // New edit session invalidates all previous revision outputs for this overlay.
                row.tilePyramidRevision += 1
                noteActivePyramidBuildRevision(o.id, revision: row.tilePyramidRevision)
                removeTilePyramidFolderFromDisk(id: o.id)
                row.tileMinimumZoom = -1
                row.tileMaximumZoom = -1
                row.tileMaximumZoomPreview = -1
                row.tileMaximumZoomFull = -1
                row.tileRefinementInProgress = true
                pyramidRebuildJobs[o.id] = row.tilePyramidRevision
                print("[TileDiag] persist.bumpRevision id=\(o.id.uuidString.prefix(8)) rev=\(row.tilePyramidRevision) cornersChanged=\(cornersChanged) forceRewriteBaked=\(forceRewriteBaked)")
            } else if !heavyTiled {
                row.tileMinimumZoom = -1
                row.tileMaximumZoom = -1
                row.tileMaximumZoomPreview = -1
                row.tileMaximumZoomFull = -1
                row.tileRefinementInProgress = false
            }

            byId[o.id] = row
            }
        }
        return pyramidRebuildJobs
    }

    /// Extend existing pyramids when stored or on-disk max **`z`** is below recomputed native detail (e.g. after a ceiling fix).
    static func resumeUnderestimatedPyramidCeilings(
        in container: NSPersistentContainer,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let tileContentScale = tileContentScaleForCurrentDevice()
        container.performBackgroundTask { context in
            let fr = StoredMapOverlay.fetchRequest()
            let rows = (try? context.fetch(fr)) ?? []
            for row in rows {
                guard let id = row.uuid,
                      row.tilePyramidRevision > 0,
                      !row.tileRefinementInProgress,
                      let source = persistedSourceImageData(row: row, overlayID: id),
                      let corners = decodeCorners(from: row.cornersJSON ?? ""),
                      corners.count == 4,
                      let bakedBlob = bakedImageDataFromDisk(id: id),
                      let bakedImg = UIImage(data: bakedBlob) else { continue }
                let storedFull = row.tileMaximumZoomFull >= 0 ? Int(row.tileMaximumZoomFull) : Int(row.tileMaximumZoom)
                let storedAdvertised = row.tileMaximumZoom >= 0 ? Int(row.tileMaximumZoom) : storedFull
                let bbox = OverlayMapBake.mapBoundingMapRect(for: corners)
                let recomputed = OverlayMapBake.nativeOverresolveMaxZoomLevelFromSourceRaster(
                    sourceRaster: source,
                    mapBoundingRect: bbox,
                    tileSizePoints: logicalTileSizePoints,
                    screenScale: tileContentScale
                )
                let disk = tilePyramidRevisionDirectoryURL(id: id, revision: row.tilePyramidRevision)
                let diskMaxZ = FileManager.default.fileExists(atPath: disk.path) ? diskMaximumZoomLevel(pyramidRoot: disk) : -1
                // Extend from what is actually on disk; stored full Z can already match recomputed while tiles stop early (~14).
                let builtThroughZ = diskMaxZ >= 0 ? diskMaxZ : max(storedFull, storedAdvertised)
                print(
                    "[TileDiag] pyramid.ceilingAudit id=\(id.uuidString.prefix(8))… storedFull=\(storedFull) advertised=\(storedAdvertised) diskMaxZ=\(diskMaxZ) builtThroughZ=\(builtThroughZ) recomputedSource=\(recomputed) tileContentScale=\(tileContentScale) physicalTilePx=\(physicalTileSizePixels(tileContentScale: tileContentScale))"
                )
                guard FileManager.default.fileExists(atPath: disk.path) else { continue }
                guard recomputed > storedFull || recomputed > builtThroughZ else { continue }
                row.tileMaximumZoom = Int32(recomputed)
                row.tileMaximumZoomFull = Int32(recomputed)
                row.tileRefinementInProgress = true
                try? context.save()
                OverlayTileRuntimeScheduler.shared.startProgressiveRuntime(
                    overlayID: id,
                    revision: row.tilePyramidRevision,
                    corners: corners,
                    sourceRaster: source,
                    bakedFallback: bakedImg,
                    tileContentScale: tileContentScale,
                    visibleMapRect: nil,
                    currentZoom: 0
                )
                print("[TileDiag] pyramid.extendCeiling.progressive id=\(id.uuidString.prefix(8))… newMaxZ=\(recomputed) builtThroughZ=\(builtThroughZ)")
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private static func scheduleMinZBuildOnly(
        overlayID: UUID,
        revision: Int64,
        container: NSPersistentContainer,
        tileContentScale: CGFloat
    ) {
        refinementQueue.async {
            guard !isPyramidBuildSuppressed(overlayID) else {
                print("[TileDiag] pyramid.skipMinZ id=\(overlayID.uuidString.prefix(8))… suppressedDuringEdit")
                return
            }
            OverlaySaveTransitionLog.stage("minZ.generation.started", overlayID: overlayID, extra: "rev=\(revision)")
            OverlayMetalTilePipeline.clearSessionCache()
            OverlayMapBake.endThumbnailCacheScope()
            container.performBackgroundTask { context in
                let fr = StoredMapOverlay.fetchRequest()
                fr.fetchLimit = 1
                fr.predicate = NSPredicate(format: "uuid == %@", overlayID as CVarArg)
                guard let row = try? context.fetch(fr).first else {
                    OverlaySaveTransitionLog.stage("minZ.generation.aborted", overlayID: overlayID, extra: "rowNotFound")
                    return
                }
                guard row.tilePyramidRevision == revision else {
                    OverlaySaveTransitionLog.stage("minZ.generation.aborted", overlayID: overlayID, extra: "revisionMismatch")
                    return
                }
                guard let source = persistedSourceImageData(row: row, overlayID: overlayID) else {
                    OverlaySaveTransitionLog.stage("minZ.generation.aborted", overlayID: overlayID, extra: "missingSource")
                    return
                }
                guard let corners = decodeCorners(from: row.cornersJSON ?? ""), corners.count == 4 else {
                    OverlaySaveTransitionLog.stage("minZ.generation.aborted", overlayID: overlayID, extra: "missingCorners")
                    return
                }
                guard let bakedBlob = bakedImageDataFromDisk(id: overlayID),
                      let bakedImg = UIImage(data: bakedBlob) else {
                    OverlaySaveTransitionLog.stage("minZ.generation.aborted", overlayID: overlayID, extra: "missingBaked")
                    return
                }
                SnapMemoryInstrumentation.checkpoint("saveTransition.minZ.beforeBuild id=\(overlayID.uuidString.prefix(8))… rev=\(revision)")
                try? OverlayTilePyramidBuilder.buildMinZOverviewAndPersistRow(
                    overlayID: overlayID,
                    revision: revision,
                    sourceRaster: source,
                    corners: corners,
                    bakedMercatorDisplay: bakedImg,
                    geometryFlipped: false,
                    tileContentScale: tileContentScale,
                    row: row,
                    context: context
                )
                OverlaySaveTransitionLog.stage("minZ.generation.finished", overlayID: overlayID, extra: "rev=\(revision)")
            }
        }
    }

    private static func scheduleBackgroundPyramidBuild(
        pyramidJobsByOverlayID: [UUID: Int64],
        container: NSPersistentContainer,
        tileContentScale: CGFloat
    ) {
        for (overlayID, revision) in pyramidJobsByOverlayID {
            scheduleMinZBuildOnly(
                overlayID: overlayID,
                revision: revision,
                container: container,
                tileContentScale: tileContentScale
            )
        }
    }

    private static func scheduleBackgroundRefinement(
        jobs: [(id: UUID, revision: Int64)],
        container: NSPersistentContainer,
        tileContentScale: CGFloat
    ) {
        for job in jobs {
            refinementQueue.async {
                guard !isPyramidBuildSuppressed(job.id) else {
                    print("[TileDiag] pyramid.skipRefine id=\(job.id.uuidString.prefix(8))… suppressedDuringEdit")
                    return
                }
                container.performBackgroundTask { context in
                    let fr = StoredMapOverlay.fetchRequest()
                    fr.fetchLimit = 1
                    fr.predicate = NSPredicate(format: "uuid == %@", job.id as CVarArg)
                    guard let row = try? context.fetch(fr).first else {
                        print("[TileDiag] pyramid.skipRefine id=\(job.id.uuidString.prefix(8))… rev=\(job.revision) reason=rowNotFound")
                        return
                    }
                    guard row.tilePyramidRevision == job.revision else {
                        print(
                            "[TileDiag] pyramid.skipRefine id=\(job.id.uuidString.prefix(8))… expectedRev=\(job.revision) rowRev=\(row.tilePyramidRevision) reason=revisionMismatch"
                        )
                        return
                    }
                    guard let source = persistedSourceImageData(row: row, overlayID: job.id) else {
                        print("[TileDiag] pyramid.skipRefine id=\(job.id.uuidString.prefix(8))… rev=\(job.revision) reason=missingSource")
                        return
                    }
                    guard let corners = decodeCorners(from: row.cornersJSON ?? ""), corners.count == 4 else {
                        print("[TileDiag] pyramid.skipRefine id=\(job.id.uuidString.prefix(8))… rev=\(job.revision) reason=missingCorners")
                        return
                    }
                    guard let bakedBlob = bakedImageDataFromDisk(id: job.id),
                          let bakedImg = UIImage(data: bakedBlob) else {
                        print("[TileDiag] pyramid.skipRefine id=\(job.id.uuidString.prefix(8))… rev=\(job.revision) reason=missingOrUndecodableBaked")
                        return
                    }
                    let bbox = OverlayMapBake.mapBoundingMapRect(for: corners)
                    let intrinsic = intrinsicPixelSize(from: source) ?? (
                        width: max(1, Int((bakedImg.size.width * bakedImg.scale).rounded())),
                        height: max(1, Int((bakedImg.size.height * bakedImg.scale).rounded()))
                    )
                    let mercator = (
                        width: max(1, bakedImg.cgImage?.width ?? intrinsic.width),
                        height: max(1, bakedImg.cgImage?.height ?? intrinsic.height)
                    )
                    let ceilings = OverlayTilePyramidBuilder.computeZoomCeilings(
                        sourceIntrinsicSize: intrinsic,
                        mercatorSize: mercator,
                        mapBoundingRect: bbox,
                        tileContentScale: tileContentScale
                    )
                    guard ceilings.firstMultiTileZoom <= ceilings.fullMaximumZ else {
                        print(
                            "[TileDiag] pyramid.skipRefine id=\(job.id.uuidString.prefix(8))… rev=\(job.revision) reason=noMultiTileRange firstMulti=\(ceilings.firstMultiTileZoom) fullMax=\(ceilings.fullMaximumZ)"
                        )
                        row.tileRefinementInProgress = ceilings.fullMaximumZ > ceilings.highestSingleTileZoom
                        try? context.save()
                        return
                    }
                    OverlayTileRuntimeScheduler.shared.startProgressiveRuntime(
                        overlayID: job.id,
                        revision: job.revision,
                        corners: corners,
                        sourceRaster: source,
                        bakedFallback: bakedImg,
                        tileContentScale: tileContentScale,
                        visibleMapRect: nil,
                        currentZoom: 0
                    )
                    print("[TileDiag] pyramid.resumeProgressive id=\(job.id.uuidString.prefix(8))… rev=\(job.revision) minZ=\(ceilings.highestSingleTileZoom) maxZ=\(ceilings.fullMaximumZ)")
                }
            }
        }
    }

    private static func scheduleBackgroundPyramidExtension(
        jobs: [(id: UUID, revision: Int64, fromZ: Int, toZ: Int)],
        container: NSPersistentContainer,
        tileContentScale: CGFloat
    ) {
        for job in jobs {
            refinementQueue.async {
                guard !isPyramidBuildSuppressed(job.id) else { return }
                container.performBackgroundTask { context in
                    let fr = StoredMapOverlay.fetchRequest()
                    fr.fetchLimit = 1
                    fr.predicate = NSPredicate(format: "uuid == %@", job.id as CVarArg)
                    guard let row = try? context.fetch(fr).first,
                          row.tilePyramidRevision == job.revision,
                          let source = persistedSourceImageData(row: row, overlayID: job.id),
                          let corners = decodeCorners(from: row.cornersJSON ?? ""),
                          corners.count == 4,
                          let bakedBlob = bakedImageDataFromDisk(id: job.id),
                          let bakedImg = UIImage(data: bakedBlob),
                          job.fromZ <= job.toZ else { return }
                    row.tileRefinementInProgress = true
                    try? context.save()
                    let previewMax = row.tileMaximumZoomPreview >= 0 ? Int(row.tileMaximumZoomPreview) : Int(row.tileMaximumZoom)
                    try? OverlayTilePyramidBuilder.buildAndPersistRow(
                        overlayID: job.id,
                        revision: job.revision,
                        sourceRaster: source,
                        corners: corners,
                        bakedMercatorDisplay: bakedImg,
                        geometryFlipped: false,
                        tileContentScale: tileContentScale,
                        buildMinimumZoom: job.fromZ,
                        buildMaximumZoom: job.toZ,
                        advertisedAvailableMaximumZoom: job.toZ,
                        targetFullMaximumZoom: job.toZ,
                        previewMaximumZoom: previewMax,
                        row: row,
                        context: context
                    )
                }
            }
        }
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

    private static func encodeCornersJSON(_ coords: [PersistedCoordinate]) throws -> String {
        let data = try JSONEncoder().encode(coords)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeCorners(from json: String) -> [CLLocationCoordinate2D]? {
        guard let data = json.data(using: .utf8),
              let coords = try? JSONDecoder().decode([PersistedCoordinate].self, from: data) else {
            return nil
        }
        return coords.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private static func encodePlacementCamera(_ cam: PersistedMapCamera?) throws -> String? {
        guard let cam else { return nil }
        let data = try JSONEncoder().encode(cam)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodePlacementCamera(from json: String?) -> PersistedMapCamera? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PersistedMapCamera.self, from: data)
    }

    /// **`MKMapRect`** in map points for the quad; enables Core Data viewport predicates without decoding image blobs.
    private static func assignGeorectMetadata(to row: StoredMapOverlay, corners: [CLLocationCoordinate2D]) {
        guard corners.count == 4 else {
            row.hasBoundingBox = false
            return
        }
        let r = OverlayMapBake.mapBoundingMapRect(for: corners)
        row.bboxMinX = r.origin.x
        row.bboxMinY = r.origin.y
        row.bboxMaxX = r.origin.x + r.size.width
        row.bboxMaxY = r.origin.y + r.size.height
        row.hasBoundingBox = true
    }

    private static func mapRectExpandedForSpatialQuery(_ rect: MKMapRect, paddingFraction: Double) -> MKMapRect {
        let w = rect.size.width
        let h = rect.size.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return MKMapRect.world }
        let mx = w * paddingFraction
        let my = h * paddingFraction
        let expanded = MKMapRect(
            origin: MKMapPoint(x: rect.origin.x - mx, y: rect.origin.y - my),
            size: MKMapSize(width: w + 2 * mx, height: h + 2 * my)
        )
        return expanded.intersection(MKMapRect.world)
    }

    private static func bakedImagesDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bakedImagesDirectoryName, isDirectory: true)
    }

    private static func bakedImageFileURL(id: UUID) -> URL {
        bakedImagesDirectoryURL().appendingPathComponent("\(id.uuidString).heic", isDirectory: false)
    }

    private static func bakedImageDataFromDisk(id: UUID) -> Data? {
        try? Data(contentsOf: bakedImageFileURL(id: id))
    }

    private static func bakedImageExistsOnDisk(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: bakedImageFileURL(id: id).path)
    }

    private static func writeBakedImageDataToDisk(_ data: Data, id: UUID) {
        let fm = FileManager.default
        let dir = bakedImagesDirectoryURL()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: bakedImageFileURL(id: id), options: .atomic)
    }

    private static func removeBakedImageFromDisk(id: UUID) {
        let url = bakedImageFileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func sourceImagesDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(sourceImagesDirectoryName, isDirectory: true)
    }

    private static func sourceImageFileURL(id: UUID) -> URL {
        sourceImagesDirectoryURL().appendingPathComponent("\(id.uuidString).bin", isDirectory: false)
    }

    private static func sourceImageDataFromDisk(id: UUID) -> Data? {
        try? Data(contentsOf: sourceImageFileURL(id: id), options: .mappedIfSafe)
    }

    private static func sourceImageExistsOnDisk(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: sourceImageFileURL(id: id).path)
    }

    private static func writeSourceImageDataToDisk(_ data: Data, id: UUID) throws {
        let fm = FileManager.default
        let dir = sourceImagesDirectoryURL()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: sourceImageFileURL(id: id), options: .atomic)
    }

    private static func removeSourceImageFromDisk(id: UUID) {
        let url = sourceImageFileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
