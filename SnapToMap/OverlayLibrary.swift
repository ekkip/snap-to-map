import CoreData
import CoreLocation
import CoreImage
import MapKit
import UIKit

/// Loads, saves, and migrates overlay data. Replaces ad-hoc `saved-overlays.json` + `overlay-images/`.
enum OverlayLibrary {

    private static let metadataFilename = "saved-overlays.json"
    private static let imagesDirectoryName = "overlay-images"
    private static let bakedImagesDirectoryName = "derived-baked-images"
    private static let bakedTileCacheDirectoryName = "snap-to-map-tile-cache"
    /// Compared in **degrees**; avoids false “corner changed” when JSON text differs only in float formatting (which forced a **full baked re-encode + source HEIC** pass on cancel/save).
    private static let cornerEqualityEpsilonDegrees: CLLocationDegrees = 1e-7
    /// Caps baked storage footprint for standard overlays (~9.4 MP; equivalent to 3072²).
    private static let bakedPersistencePixelBudget: CGFloat = 9_437_184
    /// Baked storage budget for very large overlays (~67 MP; equivalent to 8192²).
    private static let bakedPersistencePixelBudgetHighRes: CGFloat = 67_108_864
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
                  let sourceData = row.sourceImageData,
                  let sourceImage = UIImage(data: sourceData) else {
                continue
            }
            let placement = decodePlacementCamera(from: row.placementCameraJSON)
            /// Stored bake may predate high-res mercator / tiling; huge source + undersized baked blob → rebake on load.
            let minHighResBakedPixelCount: CGFloat = 150_994_944 // 12288² legacy-equivalent floor.
            let mapDisplay: UIImage
            if sourceImage.rasterExceedsLargeOverlayPixelThreshold {
                let bakedOK: UIImage? = {
                    guard let baked = bakedImageDataFromDisk(id: uuid),
                          let img = UIImage(data: baked),
                          bakedImageLikelyPreservesAlpha(img) else { return nil }
                    let bakedPixels = (img.size.width * img.scale) * (img.size.height * img.scale)
                    return bakedPixels >= minHighResBakedPixelCount ? img : nil
                }()
                if let bakedOK {
                    mapDisplay = bakedOK
                } else {
                    mapDisplay = OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: sourceImage, corners: corners) ?? sourceImage
                }
            } else if let baked = bakedImageDataFromDisk(id: uuid),
                      let img = UIImage(data: baked),
                      bakedImageLikelyPreservesAlpha(img) {
                mapDisplay = img
            } else {
                mapDisplay = OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: sourceImage, corners: corners) ?? sourceImage
            }
            result.append(
                OverlayItem(
                    id: uuid,
                    sourceImage: sourceImage,
                    mapDisplayImage: mapDisplay,
                    corners: corners,
                    placementCamera: placement,
                    preservedSourceFileData: nil
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
                try persist(overlays: snapshot, context: context, forceRewriteSource: forceS, forceRewriteBaked: forceB)
                try context.save()
                success = true
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
        guard let heic = BakedHEIFEncoder.encodeLossyWithAlpha(image: forDisk, quality: q) else {
            throw OverlayEncodeError.heicBakedEncodeFailed
        }
        return heic
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
    ) throws {
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
            row.schemaVersion = 1
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
                } else {
                    sourceBlob = try Self.encodeSourceImage(o.sourceImage)
                }
                bakedBlob = try Self.encodeBakedImage(o.mapDisplayImage)
            case (true, false):
                if let preserved = o.preservedSourceFileData {
                    sourceBlob = preserved
                } else {
                    sourceBlob = try Self.encodeSourceImage(o.sourceImage)
                }
                bakedBlob = nil
            case (false, true):
                sourceBlob = nil
                bakedBlob = try Self.encodeBakedImage(o.mapDisplayImage)
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

            byId[o.id] = row
        }
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
