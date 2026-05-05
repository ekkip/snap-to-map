import CoreData
import CoreLocation
import CoreImage
import UIKit

/// Loads, saves, and migrates overlay data. Replaces ad-hoc `saved-overlays.json` + `overlay-images/`.
enum OverlayLibrary {

    private static let metadataFilename = "saved-overlays.json"
    private static let imagesDirectoryName = "overlay-images"
    /// Compared in **degrees**; avoids false “corner changed” when JSON text differs only in float formatting (which forced a **full baked re-encode + source HEIC** pass on cancel/save).
    private static let cornerEqualityEpsilonDegrees: CLLocationDegrees = 1e-7
    /// Caps baked **storage** size so **HEIC** rasterization stays tractable on device (browse still uses in-memory / on-map resolution as before).
    private static let bakedPersistenceMaxLongEdgePoints: CGFloat = 3072
    private static let bakedDownscaleCIContext = CIContext(options: [.highQualityDownsample: true])
    /// Lossy quality for **source** rows written by this app (**HEIC**).
    private static let heifQualitySource: CGFloat = 0.88
    /// Lossy quality for **baked** mercator textures (**HEIC**).
    private static let heifQualityBaked: CGFloat = 0.82

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func legacyMetadataURL() -> URL {
        documentsDirectory().appendingPathComponent(metadataFilename)
    }

    private static func legacyImagesDirectory() -> URL {
        documentsDirectory().appendingPathComponent(imagesDirectoryName, isDirectory: true)
    }

    private static func overlayImageFilename(id: UUID) -> String {
        "\(id.uuidString).png"
    }

    private static func overlayBakedImageFilename(id: UUID) -> String {
        "\(id.uuidString)-baked.png"
    }

    private static func overlayLegacyBakedJpegFilename(id: UUID) -> String {
        "\(id.uuidString)-baked.jpg"
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

    // MARK: - Public API

    /// **Opaque** baked blobs (e.g. legacy **JPEG**) drop transparency → rebake from **`sourceImage`** on load so the map isn’t white outside the quad.
    /// **HEIF** (ISO BMFF `ftyp`), **PNG**, and legacy **WebP** blobs are treated as alpha-capable.
    private static func bakedBlobLikelyPreservesAlpha(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let prefix = data.prefix(8)
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if data.prefix(4) == Data([0x52, 0x49, 0x46, 0x46]), data.subdata(in: 8..<12) == Data([0x57, 0x45, 0x42, 0x50]) {
            return true
        }
        if dataLooksLikeHEIFContainer(data) { return true }
        return false
    }

    /// **`ftyp`** at offset 4; still-image / HEIC major brands used by ImageIO.
    private static func dataLooksLikeHEIFContainer(_ data: Data) -> Bool {
        guard data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 else { return false }
        let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
        let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heif"]
        return heifBrands.contains(brand)
    }

    static func loadOverlays(viewContext: NSManagedObjectContext) throws -> [OverlayItem] {
        let request = StoredMapOverlay.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredMapOverlay.sortOrder, ascending: true)]
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
            let mapDisplay: UIImage
            if let baked = row.bakedImageData,
               bakedBlobLikelyPreservesAlpha(baked),
               let img = UIImage(data: baked) {
                mapDisplay = img
            } else {
                mapDisplay = OverlayMapBake.bakeMercatorDisplayTexture(source: sourceImage, corners: corners) ?? sourceImage
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

    // MARK: - Legacy import

    /// **`true`** if legacy rows were inserted (caller should **`save`** then delete legacy files).
    @discardableResult
    static func importLegacyJSONAndPNGsIfStoreEmpty(context: NSManagedObjectContext) throws -> Bool {
        let count = try context.count(for: StoredMapOverlay.fetchRequest())
        if count > 0 { return false }

        guard FileManager.default.fileExists(atPath: legacyMetadataURL().path) else { return false }

        let metadataData = try Data(contentsOf: legacyMetadataURL())
        let persisted = try JSONDecoder().decode(PersistedOverlays.self, from: metadataData)
        guard !persisted.entries.isEmpty else { return false }

        let directoryURL = legacyImagesDirectory()

        for (index, entry) in persisted.entries.enumerated() {
            guard entry.corners.count == 4 else { throw ImportError.invalidCorners }

            let imageURL = directoryURL.appendingPathComponent(overlayImageFilename(id: entry.id))
            let imageData = try Data(contentsOf: imageURL)
            guard UIImage(data: imageData) != nil else { throw ImportError.missingSourceImage }

            let bakedPNGURL = directoryURL.appendingPathComponent(overlayBakedImageFilename(id: entry.id))
            let bakedLegacyJPGURL = directoryURL.appendingPathComponent(overlayLegacyBakedJpegFilename(id: entry.id))
            let bakedData: Data?
            if let url = [bakedPNGURL, bakedLegacyJPGURL].first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                bakedData = try Data(contentsOf: url)
            } else {
                bakedData = nil
            }

            let now = Date()
            let coords = entry.corners.map { PersistedCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            let cornersJSON = try Self.encodeCornersJSON(coords)
            let placementJSON = try encodePlacementCamera(entry.placementCamera)

            let row = StoredMapOverlay(context: context)
            row.uuid = entry.id
            row.schemaVersion = 1
            row.sortOrder = Int32(index)
            row.cornersJSON = cornersJSON
            row.placementCameraJSON = placementJSON
            row.sourceImageData = imageData
            row.bakedImageData = bakedData
            row.createdAt = now
            row.modifiedAt = now
        }
        return true
    }

    /// Call only after a successful **`save()`** of a full legacy import.
    static func deleteLegacyOverlayFileBundleIfPresent() {
        let fm = FileManager.default
        try? fm.removeItem(at: legacyMetadataURL())
        try? fm.removeItem(at: legacyImagesDirectory())
    }

    private enum ImportError: Error {
        case invalidCorners
        case missingSourceImage
    }

    // MARK: - Private

    /// **HEIC** via **ImageIO**, then **PNG** only if the HEIC encoder refuses (Simulator quirks, rare failures).
    private static func encodeSourceImage(_ image: UIImage) -> Data? {
        if let heic = BakedHEIFEncoder.encodeLossyWithAlpha(image: image, quality: heifQualitySource) { return heic }
        return image.pngData()
    }

    /// Mercator bake keeps **transparency** outside the warped quad. **HEIC** for disk; **PNG** only as last-resort fallback (same as source).
    private static func encodeBakedImage(_ image: UIImage) -> Data? {
        let forDisk = imageScaledForBakedPersistence(image)
        if let heic = BakedHEIFEncoder.encodeLossyWithAlpha(image: forDisk, quality: heifQualityBaked) { return heic }
        return forDisk.pngData()
    }

    private static func imageScaledForBakedPersistence(_ image: UIImage) -> UIImage {
        let maxE = bakedPersistenceMaxLongEdgePoints
        let pxW = image.size.width * image.scale
        let pxH = image.size.height * image.scale
        let long = max(pxW, pxH)
        guard long > maxE, long > 0, let ci = CIImage(image: image) else { return image }
        let s = maxE / long
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
            let needsBakedWrite = forceRewriteBaked || cornersChanged || row.bakedImageData == nil

            let sourceBlob: Data?
            let bakedBlob: Data?
            switch (needsSourceWrite, needsBakedWrite) {
            case (true, true):
                if let raw = o.preservedSourceFileData {
                    sourceBlob = raw
                } else {
                    sourceBlob = Self.encodeSourceImage(o.sourceImage)
                }
                bakedBlob = Self.encodeBakedImage(o.mapDisplayImage)
            case (true, false):
                if let raw = o.preservedSourceFileData {
                    sourceBlob = raw
                } else {
                    sourceBlob = Self.encodeSourceImage(o.sourceImage)
                }
                bakedBlob = nil
            case (false, true):
                sourceBlob = nil
                bakedBlob = Self.encodeBakedImage(o.mapDisplayImage)
            case (false, false):
                sourceBlob = nil
                bakedBlob = nil
            }

            if let sourceBlob {
                row.sourceImageData = sourceBlob
            }
            if let bakedBlob {
                row.bakedImageData = bakedBlob
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
}
