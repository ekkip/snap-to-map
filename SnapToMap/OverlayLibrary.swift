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
    /// Legacy 1× label kept for diagnostics; native max-zoom math must match **`MKTileOverlay`** **`contentScaleFactor`** on device.
    static let tileDetailReferenceScale: CGFloat = 1

    /// Screen scale for pyramid native-max and per-tile pixel budgets (typically **2** or **3** on iPhone).
    static func tileDetailScreenScaleForNativeMaxZoom() -> CGFloat {
        max(1, UIScreen.main.scale)
    }

    private static let metadataFilename = "saved-overlays.json"
    private static let imagesDirectoryName = "overlay-images"
    private static let bakedImagesDirectoryName = "derived-baked-images"
    private static let bakedTileCacheDirectoryName = "snap-to-map-tile-cache"
    private static let overlayTilePyramidsDirectoryName = "overlay-tile-pyramids"
    private static let workingImagesDirectoryName = "snap-to-map-working-images"
    /// Compared in **degrees**; avoids false “corner changed” when JSON text differs only in float formatting (which forced a **full baked re-encode + source HEIC** pass on cancel/save).
    private static let cornerEqualityEpsilonDegrees: CLLocationDegrees = 1e-7
    /// Caps baked storage footprint for standard overlays (~9.4 MP; equivalent to 3072²).
    private static let bakedPersistencePixelBudget: CGFloat = 9_437_184
    /// Baked storage budget for very large overlays (~16.8 MP; equivalent to 4096²).
    /// Runtime tile LOD restores zoom detail from source raster without persisting huge bakes.
    private static let bakedPersistencePixelBudgetHighRes: CGFloat = 16_777_216
    /// Source raster size threshold that switches bake/persistence into high-res budgets.
    static let largeRasterOverlayPixelThresholdExclusive: Int64 = 100_000_000
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
                  let sourceData = row.sourceImageData else {
                continue
            }
            let sourcePixels = UIImage.rasterPixelCount(forCompressedImageData: sourceData)
                ?? Int64.max
            let isHeavy = sourcePixels > largeRasterOverlayPixelThresholdExclusive

            let sourceImage: UIImage
            if isHeavy {
                sourceImage = OverlayItem.browseSourceMemoryPlaceholder()
            } else {
                guard let decoded = UIImage(data: sourceData) else { continue }
                sourceImage = decoded
            }

            let placement = decodePlacementCamera(from: row.placementCameraJSON)
            /// Stored bake may predate high-res mercator / tiling; huge source + undersized baked blob → rebake on load.
            let minHighResBakedPixelCount: CGFloat = 150_994_944 // 12288² legacy-equivalent floor.
            let mapDisplay: UIImage
            if isHeavy {
                let bakedOK: UIImage? = {
                    guard let baked = bakedImageDataFromDisk(id: uuid),
                          let img = UIImage(data: baked),
                          bakedImageLikelyPreservesAlpha(img) else { return nil }
                    let bakedPixels = (img.size.width * img.scale) * (img.size.height * img.scale)
                    return bakedPixels >= minHighResBakedPixelCount ? img : nil
                }()
                if let bakedOK {
                    mapDisplay = bakedOK
                } else if let full = UIImage(data: sourceData) {
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
                let rev = row.tilePyramidRevision
                guard rev > 0,
                      row.tileMinimumZoom >= 0,
                      row.tileMaximumZoom >= row.tileMinimumZoom else { return nil }
                let disk = tilePyramidRevisionDirectoryURL(id: uuid, revision: rev)
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
            }()
            if isHeavy {
                let runtimeLabel: String
                if let runtime = tilePyramidRuntime {
                    let root = tilePyramidRevisionDirectoryURL(id: uuid, revision: runtime.revision)
                    let counts = debugTilePyramidPNGCountsByZoom(pyramidRoot: root)
                    let levels = counts.keys.sorted().map { "z\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
                    runtimeLabel = "rev=\(runtime.revision) minZ=\(runtime.minimumZoom) maxZ=\(runtime.maximumZoom) previewMax=\(runtime.previewMaximumZoom) fullMax=\(runtime.fullMaximumZoom) refining=\(runtime.refinementInProgress) rootExists=\(FileManager.default.fileExists(atPath: root.path)) levels=[\(levels)]"
                } else {
                    runtimeLabel = "missing runtime (rowRev=\(row.tilePyramidRevision) rowMinZ=\(row.tileMinimumZoom) rowMaxZ=\(row.tileMaximumZoom))"
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
                    sourceRasterData: sourceData,
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

    /// On app restart, continue any interrupted refinement jobs where possible and clear stale flags
    /// when the row is already complete or required assets are missing.
    static func resumePendingRefinements(
        in container: NSPersistentContainer,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let referenceScreenScale = tileDetailScreenScaleForNativeMaxZoom()
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
                let hasSource = row.sourceImageData != nil
                let hasCorners = decodeCorners(from: row.cornersJSON ?? "")?.count == 4
                let hasBaked = bakedImageDataFromDisk(id: id) != nil
                if hasValidRange, hasRevision, hasSource, hasCorners, hasBaked {
                    jobs.append((id: id, revision: row.tilePyramidRevision))
                } else {
                    row.tileRefinementInProgress = false
                }
            }
            if context.hasChanges {
                try? context.save()
            }
            if !jobs.isEmpty {
                scheduleBackgroundRefinement(
                    jobs: jobs,
                    container: container,
                    referenceScreenScale: referenceScreenScale
                )
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
        let referenceScreenScale = tileDetailScreenScaleForNativeMaxZoom()

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
                SnapMemoryInstrumentation.checkpoint("persist.bg.afterContextSave pyramidJobKeys=\(pyramidJobs.count)")

                if !pyramidJobs.isEmpty {
                    scheduleBackgroundPreviewBuild(
                        pyramidJobsByOverlayID: pyramidJobs,
                        container: container,
                        referenceScreenScale: referenceScreenScale
                    )
                }
            } catch {
                #if DEBUG
                print("OverlayLibrary save failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Private

    /// Always writes source rows as **HEIC**.
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
            removeTilePyramidFolderFromDisk(id: id)
            context.delete(row)
            byId.removeValue(forKey: id)
        }

        let now = Date()
        for (index, o) in overlays.enumerated() {
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
            let needsSourceWrite = forceRewriteSource || row.sourceImageData == nil
            let needsBakedWrite = forceRewriteBaked || cornersChanged || !bakedImageExistsOnDisk(id: o.id)

            let sourceBlob: Data?
            let bakedBlob: Data?
            switch (needsSourceWrite, needsBakedWrite) {
            case (true, true):
                if let preserved = o.preservedSourceFileData {
                    sourceBlob = preserved
                } else if let rd = o.sourceRasterData, !rd.isEmpty {
                    sourceBlob = rd
                } else {
                    sourceBlob = try autoreleasepool {
                        try Self.encodeSourceImage(o.sourceImage)
                    }
                }
                bakedBlob = try autoreleasepool {
                    try Self.encodeBakedImage(o.mapDisplayImage)
                }
            case (true, false):
                if let preserved = o.preservedSourceFileData {
                    sourceBlob = preserved
                } else if let rd = o.sourceRasterData, !rd.isEmpty {
                    sourceBlob = rd
                } else {
                    sourceBlob = try autoreleasepool {
                        try Self.encodeSourceImage(o.sourceImage)
                    }
                }
                bakedBlob = nil
            case (false, true):
                sourceBlob = nil
                bakedBlob = try autoreleasepool {
                    try Self.encodeBakedImage(o.mapDisplayImage)
                }
            case (false, false):
                sourceBlob = nil
                bakedBlob = nil
            }

            if let sourceBlob {
                row.sourceImageData = sourceBlob
            }
            if let bakedBlob {
                writeBakedImageDataToDisk(bakedBlob, id: o.id)
            }

            let heavyTiled = o.usesTiledMapPresentation
            if needsBakedWrite && heavyTiled {
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
        return pyramidRebuildJobs
    }

    /// After a device-scale fix, extend existing pyramids whose stored **`tileMaximumZoomFull`** underestimated native detail (~1.6 z on 3× iPhone).
    static func resumeUnderestimatedPyramidCeilings(
        in container: NSPersistentContainer,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let referenceScreenScale = tileDetailScreenScaleForNativeMaxZoom()
        container.performBackgroundTask { context in
            let fr = StoredMapOverlay.fetchRequest()
            let rows = (try? context.fetch(fr)) ?? []
            var jobs: [(id: UUID, revision: Int64, fromZ: Int, toZ: Int)] = []
            for row in rows {
                guard let id = row.uuid,
                      row.tilePyramidRevision > 0,
                      !row.tileRefinementInProgress,
                      let source = row.sourceImageData,
                      let corners = decodeCorners(from: row.cornersJSON ?? ""),
                      corners.count == 4 else { continue }
                let storedFull = row.tileMaximumZoomFull >= 0 ? Int(row.tileMaximumZoomFull) : Int(row.tileMaximumZoom)
                let storedAdvertised = row.tileMaximumZoom >= 0 ? Int(row.tileMaximumZoom) : storedFull
                let bbox = OverlayMapBake.mapBoundingMapRect(for: corners)
                let recomputed = OverlayMapBake.nativeMaxZoomLevelFromSourceRaster(
                    sourceRaster: source,
                    mapBoundingRect: bbox,
                    tileSizePoints: logicalTileSizePoints,
                    screenScale: referenceScreenScale
                )
                let disk = tilePyramidRevisionDirectoryURL(id: id, revision: row.tilePyramidRevision)
                let diskMaxZ = FileManager.default.fileExists(atPath: disk.path) ? diskMaximumZoomLevel(pyramidRoot: disk) : -1
                // Extend from what is actually on disk; stored full Z can already match recomputed while tiles stop early (~14).
                let builtThroughZ = diskMaxZ >= 0 ? diskMaxZ : max(storedFull, storedAdvertised)
                print(
                    "[TileDiag] pyramid.ceilingAudit id=\(id.uuidString.prefix(8))… storedFull=\(storedFull) advertised=\(storedAdvertised) diskMaxZ=\(diskMaxZ) builtThroughZ=\(builtThroughZ) recomputedSource=\(recomputed) scale=\(referenceScreenScale)"
                )
                guard FileManager.default.fileExists(atPath: disk.path) else { continue }
                guard recomputed > builtThroughZ else { continue }
                jobs.append((id: id, revision: row.tilePyramidRevision, fromZ: builtThroughZ + 1, toZ: recomputed))
                print("[TileDiag] pyramid.extendCeiling id=\(id.uuidString.prefix(8))… fromZ=\(builtThroughZ + 1) toZ=\(recomputed)")
            }
            if !jobs.isEmpty {
                scheduleBackgroundPyramidExtension(jobs: jobs, container: container, referenceScreenScale: referenceScreenScale)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private static func scheduleBackgroundPreviewBuild(
        pyramidJobsByOverlayID: [UUID: Int64],
        container: NSPersistentContainer,
        referenceScreenScale: CGFloat
    ) {
        for (overlayID, revision) in pyramidJobsByOverlayID {
            let overlayID = overlayID
            let revision = revision
            refinementQueue.async(execute: DispatchWorkItem {
                guard !isPyramidBuildSuppressed(overlayID) else {
                    print("[TileDiag] pyramid.skipPreview id=\(overlayID.uuidString.prefix(8))… suppressedDuringEdit")
                    return
                }
                container.performBackgroundTask { context in
                    let fr = StoredMapOverlay.fetchRequest()
                    fr.fetchLimit = 1
                    fr.predicate = NSPredicate(format: "uuid == %@", overlayID as CVarArg)
                    guard let row = try? context.fetch(fr).first,
                          row.tilePyramidRevision == revision,
                          let source = row.sourceImageData,
                          let corners = decodeCorners(from: row.cornersJSON ?? ""),
                          corners.count == 4,
                          let bakedBlob = bakedImageDataFromDisk(id: overlayID),
                          let bakedImg = UIImage(data: bakedBlob) else {
                        return
                    }
                    SnapMemoryInstrumentation.checkpoint("pyramid.batch.begin jobs=1 id=\(overlayID.uuidString.prefix(8))… rev=\(revision)")
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
                        referenceScreenScale: referenceScreenScale
                    )
                    try? OverlayTilePyramidBuilder.buildAndPersistRow(
                        overlayID: overlayID,
                        revision: revision,
                        sourceRaster: source,
                        corners: corners,
                        bakedMercatorDisplay: bakedImg,
                        geometryFlipped: false,
                        referenceScreenScale: referenceScreenScale,
                        phase: .preview,
                        buildMinimumZoom: ceilings.minimumZ,
                        buildMaximumZoom: ceilings.previewMaximumZ,
                        advertisedAvailableMaximumZoom: ceilings.previewMaximumZ,
                        targetFullMaximumZoom: ceilings.fullMaximumZ,
                        previewMaximumZoom: ceilings.previewMaximumZ,
                        row: row,
                        context: context
                    )
                    SnapMemoryInstrumentation.checkpoint("pyramid.batch.afterJob id=\(overlayID.uuidString.prefix(8))… rev=\(revision)")
                    if ceilings.fullMaximumZ > ceilings.previewMaximumZ {
                        scheduleBackgroundRefinement(
                            jobs: [(id: overlayID, revision: revision)],
                            container: container,
                            referenceScreenScale: referenceScreenScale
                        )
                    }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .overlayTilePyramidRefinementDidComplete,
                            object: nil,
                            userInfo: ["overlayID": overlayID.uuidString]
                        )
                    }
                }
            })
        }
    }

    private static func scheduleBackgroundRefinement(
        jobs: [(id: UUID, revision: Int64)],
        container: NSPersistentContainer,
        referenceScreenScale: CGFloat
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
                    guard let row = try? context.fetch(fr).first,
                          row.tilePyramidRevision == job.revision,
                          let source = row.sourceImageData,
                          let corners = decodeCorners(from: row.cornersJSON ?? ""),
                          corners.count == 4,
                          let bakedBlob = bakedImageDataFromDisk(id: job.id),
                          let bakedImg = UIImage(data: bakedBlob) else {
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
                        referenceScreenScale: referenceScreenScale
                    )
                    guard ceilings.fullMaximumZ > ceilings.previewMaximumZ else { return }
                    try? OverlayTilePyramidBuilder.buildAndPersistRow(
                        overlayID: job.id,
                        revision: job.revision,
                        sourceRaster: source,
                        corners: corners,
                        bakedMercatorDisplay: bakedImg,
                        geometryFlipped: false,
                        referenceScreenScale: referenceScreenScale,
                        phase: .refine,
                        buildMinimumZoom: ceilings.previewMaximumZ + 1,
                        buildMaximumZoom: ceilings.fullMaximumZ,
                        advertisedAvailableMaximumZoom: ceilings.fullMaximumZ,
                        targetFullMaximumZoom: ceilings.fullMaximumZ,
                        previewMaximumZoom: ceilings.previewMaximumZ,
                        row: row,
                        context: context
                    )
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .overlayTilePyramidRefinementDidComplete,
                            object: nil,
                            userInfo: ["overlayID": job.id.uuidString]
                        )
                    }
                }
            }
        }
    }

    private static func scheduleBackgroundPyramidExtension(
        jobs: [(id: UUID, revision: Int64, fromZ: Int, toZ: Int)],
        container: NSPersistentContainer,
        referenceScreenScale: CGFloat
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
                          let source = row.sourceImageData,
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
                        referenceScreenScale: referenceScreenScale,
                        phase: .refine,
                        buildMinimumZoom: job.fromZ,
                        buildMaximumZoom: job.toZ,
                        advertisedAvailableMaximumZoom: job.toZ,
                        targetFullMaximumZoom: job.toZ,
                        previewMaximumZoom: previewMax,
                        row: row,
                        context: context
                    )
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .overlayTilePyramidRefinementDidComplete,
                            object: nil,
                            userInfo: ["overlayID": job.id.uuidString]
                        )
                    }
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
}
