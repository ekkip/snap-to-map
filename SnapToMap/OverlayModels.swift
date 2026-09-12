import CoreLocation
import Foundation
import UIKit

/// Runtime-progressive tile generation defaults (also persisted in **`pyramid-meta.json`**).
struct OverlayProgressiveTileConfig: Equatable, Codable {
    var prewarmLookaheadZooms: Int
    var earlyComfortDepth: Int
    var cheapLevelTileLimit: Int
    var prewarmMarginScreens: Double
    var maxConcurrentSourceChunkJobs: Int
    var maxConcurrentOutputTileJobs: Int
    var maxResidentSourceChunks: Int
    var sourceChunkSize: Int

    static let `default` = OverlayProgressiveTileConfig(
        prewarmLookaheadZooms: 2,
        earlyComfortDepth: 2,
        cheapLevelTileLimit: 32,
        prewarmMarginScreens: 1.5,
        maxConcurrentSourceChunkJobs: 1,
        maxConcurrentOutputTileJobs: 1,
        maxResidentSourceChunks: 6,
        sourceChunkSize: 4096
    )
}

/// Map framing when the overlay was last committed (**«Done»**), so re-opening edit can restore heading / zoom / center.
struct PersistedMapCamera: Codable, Equatable {
    var centerLatitude: CLLocationDegrees
    var centerLongitude: CLLocationDegrees
    /// Degrees, clockwise from north (`MKMapCamera.heading`).
    var heading: CLLocationDirection
    /// Meters from the ground to the camera (`MKMapCamera.centerCoordinateDistance`).
    var centerCoordinateDistance: CLLocationDistance
    /// Degrees; stored as `Double` for stable JSON (`MKMapCamera.pitch`).
    var pitch: Double
}

/// Stable identity for a single pyramid output tile (runtime dedup / state).
struct OverlayTileCoordinateKey: Hashable {
    let overlayID: UUID
    let revision: Int64
    let z: Int
    let x: Int
    let y: Int
    let scale100: Int
}

/// Explicit runtime lifecycle for lazily generated output tiles.
enum OverlayRuntimeTileState: Equatable {
    case missing
    case generating
    case ready
    case failed
}

/// Disk-backed **`MKTileOverlay`** pyramid metadata (**`-1`** zoom sentinel ⇒ pyramid rebuild in flight).
struct OverlayTilePyramidRuntimeInfo: Equatable {
    let revision: Int64
    let minimumZoom: Int32
    let maximumZoom: Int32
    let previewMaximumZoom: Int32
    let fullMaximumZoom: Int32
    let refinementInProgress: Bool
}

struct OverlayItem: Identifiable {
    let id: UUID
    /// Concise human label derived from the overlay georect; shown in browse UI.
    let displayName: String?
    /// Original photo metadata holder for **re‑edit** / persistence; may be **`browseSourceMemoryPlaceholder()`** when **`sourceRasterData`** holds the full raster (**no huge decoded bitmap** in browse).
    let sourceImage: UIImage
    /// Mercator **bounding-box** texture used on the map in browse mode (**`OverlayMapPresentation`**: raster or tiled; see **`OverlayMapBake`**).
    let mapDisplayImage: UIImage
    /// Derived from **`sourceRasterData`** (**ImageIO** pixel dimensions when present) or from **`sourceImage`** pixels — drives **`BakedImageMapTileOverlay`** vs **`ImageRasterMapOverlay`** (`>` **`OverlayLibrary.largeRasterOverlayPixelThresholdExclusive`**).
    let usesTiledMapPresentation: Bool
    let corners: [CLLocationCoordinate2D]
    /// Framing at save time; when present, edit mode restores this camera instead of fitting a north-up rect.
    let placementCamera: PersistedMapCamera?
    /// Camera-roll file bytes from **`PhotosPicker`** kept only in memory for immediate editing workflows; persistence writes re-encode from `sourceImage`.
    var preservedSourceFileData: Data?
    /// Set when save draft already wrote derived baked HEIC to disk; **`persist`** skips re-encode.
    var bakedImagePreWrittenToDisk: Bool = false
    /// Legacy only: **`true`** when source bytes exist only under Application Support, not yet in **`sourceImageData`**.
    var sourceImagePreWrittenToDisk: Bool = false
    /// Pixel count when **`sourceRasterData`** is omitted after disk pre-write (heavy overlay save draft).
    let cachedSourceRasterPixels: Int64?
    /// Compressed source raster (**JPEG** / **HEIC** …) for **`ImageIO`** subsampled tile draws on huge overlays; avoids decoding the full bitmap while zoomed in.
    let sourceRasterData: Data?
    /// Present after **`OverlayTilePyramidBuilder`** completes; **`nil`** uses lazy **`TileCache`** rasterizing until pyramid metadata arrives from persistence reload.
    let tilePyramid: OverlayTilePyramidRuntimeInfo?

    init(
        id: UUID,
        displayName: String? = nil,
        sourceImage: UIImage,
        mapDisplayImage: UIImage,
        corners: [CLLocationCoordinate2D],
        placementCamera: PersistedMapCamera?,
        preservedSourceFileData: Data? = nil,
        bakedImagePreWrittenToDisk: Bool = false,
        sourceImagePreWrittenToDisk: Bool = false,
        cachedSourceRasterPixels: Int64? = nil,
        sourceRasterData: Data? = nil,
        tilePyramid: OverlayTilePyramidRuntimeInfo? = nil
    ) {
        self.id = id
        self.displayName = OverlayNameResolver.normalizedDisplayName(displayName)
        self.sourceImage = sourceImage
        self.mapDisplayImage = mapDisplayImage
        self.bakedImagePreWrittenToDisk = bakedImagePreWrittenToDisk
        self.sourceImagePreWrittenToDisk = sourceImagePreWrittenToDisk
        self.cachedSourceRasterPixels = cachedSourceRasterPixels
        let tiledPixels: Int64 = {
            if let cachedSourceRasterPixels { return cachedSourceRasterPixels }
            if let data = sourceRasterData, !data.isEmpty,
               let n = UIImage.rasterPixelCount(forCompressedImageData: data) {
                return n
            }
            return sourceImage.rasterPixelCount()
        }()
        self.usesTiledMapPresentation = tiledPixels > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive
        self.corners = corners
        self.placementCamera = placementCamera
        self.preservedSourceFileData = preservedSourceFileData
        self.sourceRasterData = sourceRasterData
        self.tilePyramid = tilePyramid
    }

    var resolvedDisplayName: String {
        displayName ?? OverlayNameResolver.fallbackDisplayName
    }

    /// Decode path for **edit** UI only — prefer **`ImageIO`** subsampling so **`CIImage`** never sees a 400 MP backing.
    func editingPreviewUIImage(maxPixelDimension: CGFloat = 8192) -> UIImage? {
        if let data = sourceRasterData, !data.isEmpty {
            return OverlayLibrary.uiImageSubsampling(from: data, maxPixelDimension: maxPixelDimension)
                ?? UIImage(data: data)
        }
        if sourceImagePreWrittenToDisk,
           let data = OverlayLibrary.persistedSourceRasterData(overlayID: id),
           !data.isEmpty {
            return OverlayLibrary.uiImageSubsampling(from: data, maxPixelDimension: maxPixelDimension)
                ?? UIImage(data: data)
        }
        return sourceImage
    }

    /// Small browse-panel thumbnail in import orientation (**ImageIO** subsample + EXIF transform).
    func panelPreviewUIImage(maxPixelDimension: CGFloat = 256) -> UIImage? {
        if let data = sourceRasterData, !data.isEmpty {
            return OverlayLibrary.uiImageSubsampling(from: data, maxPixelDimension: maxPixelDimension)
        }
        if sourceImagePreWrittenToDisk,
           let data = OverlayLibrary.persistedSourceRasterData(overlayID: id),
           !data.isEmpty {
            return OverlayLibrary.uiImageSubsampling(from: data, maxPixelDimension: maxPixelDimension)
        }
        if sourceImage.size.width > 1 || sourceImage.size.height > 1 {
            return sourceImage
        }
        return nil
    }

    /// Placeholder bitmap for **`sourceImage`** while **`sourceRasterData`** retains the real pixels (**browse** stays memory‑flat).
    static func browseSourceMemoryPlaceholder() -> UIImage { browseSourceMemoryPlaceholderImage }

    private static let browseSourceMemoryPlaceholderImage: UIImage = {
        let size = CGSize(width: 1, height: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let r = UIGraphicsImageRenderer(size: size, format: format)
        return r.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }()
}

enum OverlayNameResolver {
    static let fallbackDisplayName = "Untitled overlay"

    private static let nominatimEndpoint = URL(string: "https://nominatim.openstreetmap.org/reverse")!
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let nominatimRateLimitLock = NSLock()
    private static var nominatimNextRequestDate = Date.distantPast

    private enum NominatimLookupResult {
        case found(String)
        case retryableMiss
        case terminalFailure
    }

    struct Georect {
        let minLatitude: CLLocationDegrees
        let maxLatitude: CLLocationDegrees
        let minLongitude: CLLocationDegrees
        let maxLongitude: CLLocationDegrees

        var centerLatitude: CLLocationDegrees { (minLatitude + maxLatitude) / 2 }
        var centerLongitude: CLLocationDegrees { (minLongitude + maxLongitude) / 2 }
        var maxSpanDegrees: CLLocationDegrees {
            max(abs(maxLatitude - minLatitude), abs(maxLongitude - minLongitude))
        }
    }

    static func displayName(for corners: [CLLocationCoordinate2D], fallback: String? = nil) async -> String? {
        if let name = await nominatimDisplayName(for: corners) {
            return name
        }
        return normalizedDisplayName(fallback)
    }

    static func normalizedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == fallbackDisplayName { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func georect(for corners: [CLLocationCoordinate2D]) -> Georect? {
        guard !corners.isEmpty else { return nil }
        let lats = corners.map(\.latitude)
        let lons = corners.map(\.longitude)
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return nil
        }
        return Georect(
            minLatitude: minLat,
            maxLatitude: maxLat,
            minLongitude: minLon,
            maxLongitude: maxLon
        )
    }

    static func nominatimZoom(for georect: Georect) -> Int {
        switch georect.maxSpanDegrees {
        case ..<0.002: return 18
        case ..<0.005: return 17
        case ..<0.01: return 16
        case ..<0.025: return 15
        case ..<0.05: return 14
        case ..<0.1: return 13
        case ..<0.25: return 12
        case ..<0.5: return 11
        case ..<1: return 10
        case ..<2: return 9
        case ..<4: return 8
        case ..<8: return 7
        case ..<16: return 6
        case ..<32: return 5
        default: return 4
        }
    }

    private static func nominatimDisplayName(for corners: [CLLocationCoordinate2D]) async -> String? {
        guard let georect = georect(for: corners) else { return nil }
        let primaryZoom = nominatimZoom(for: georect)
        for zoom in reverseZoomSequence(startingAt: primaryZoom) {
            switch await requestNominatimDisplayName(for: georect, zoom: zoom) {
            case .found(let name):
                return name
            case .retryableMiss:
                continue
            case .terminalFailure:
                return nil
            }
        }
        return nil
    }

    private static func requestNominatimDisplayName(for georect: Georect, zoom: Int) async -> NominatimLookupResult {
        guard var components = URLComponents(url: nominatimEndpoint, resolvingAgainstBaseURL: false) else {
            return .terminalFailure
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: coordinateQueryValue(georect.centerLatitude)),
            URLQueryItem(name: "lon", value: coordinateQueryValue(georect.centerLongitude)),
            URLQueryItem(name: "zoom", value: "\(zoom)"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "namedetails", value: "1"),
        ]
        guard let url = components.url else { return .terminalFailure }

        var request = URLRequest(url: url)
        request.setValue("SnapToMap/1.0 overlay-naming", forHTTPHeaderField: "User-Agent")
        request.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 12

        do {
            await waitForNominatimRateLimit()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("[OverlayName] Nominatim lookup failed: non-HTTP response")
                return .terminalFailure
            }
            guard http.statusCode == 200 else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? "<\(data.count) bytes>"
                print("[OverlayName] Nominatim HTTP \(http.statusCode) zoom=\(zoom): \(body)")
                return (400..<500).contains(http.statusCode) ? .terminalFailure : .retryableMiss
            }
            let decoded = try JSONDecoder().decode(NominatimReverseResponse.self, from: data)
            guard let name = preferredName(from: decoded, zoom: zoom) else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? "<\(data.count) bytes>"
                print("[OverlayName] Nominatim returned no usable name zoom=\(zoom): \(body)")
                return .retryableMiss
            }
            return .found(name)
        } catch {
            print("[OverlayName] Nominatim lookup failed: \(error)")
            return .terminalFailure
        }
    }

    private static func coordinateQueryValue(_ value: CLLocationDegrees) -> String {
        String(format: "%.7f", locale: posixLocale, value)
    }

    private static func reverseZoomSequence(startingAt zoom: Int) -> [Int] {
        var seen = Set<Int>()
        return ([zoom] + [14, 12, 10, 8, 6, 4])
            .filter { fallback in
                guard (3...18).contains(fallback), fallback <= zoom, !seen.contains(fallback) else {
                    return false
                }
                seen.insert(fallback)
                return true
            }
    }

    private static func waitForNominatimRateLimit() async {
        let delay: TimeInterval = {
            nominatimRateLimitLock.lock()
            defer { nominatimRateLimitLock.unlock() }
            let now = Date()
            let wait = max(0, nominatimNextRequestDate.timeIntervalSince(now))
            nominatimNextRequestDate = now.addingTimeInterval(wait + 1)
            return wait
        }()
        guard delay > 0 else { return }
        let nanoseconds = UInt64((delay * 1_000_000_000).rounded())
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func preferredName(from response: NominatimReverseResponse, zoom: Int) -> String? {
        let addressKeys: [String]
        if zoom >= 15 {
            addressKeys = ["road", "neighbourhood", "suburb", "city_district", "quarter", "city", "town", "village"]
        } else if zoom >= 11 {
            addressKeys = ["suburb", "city_district", "quarter", "neighbourhood", "city", "town", "village", "municipality"]
        } else {
            addressKeys = ["city", "town", "village", "municipality", "county", "state", "country"]
        }

        let addressCandidates = addressKeys.compactMap { response.address?[$0] }
        let fallbackCandidates = [
            response.namedetails?["name"],
            response.name,
            response.displayName?.split(separator: ",").first.map(String.init),
        ]
        return (addressCandidates + fallbackCandidates.compactMap { $0 })
            .lazy
            .compactMap { normalizedDisplayName($0) }
            .first
    }

    private struct NominatimReverseResponse: Decodable {
        let name: String?
        let displayName: String?
        let address: [String: String]?
        let namedetails: [String: String]?

        enum CodingKeys: String, CodingKey {
            case name
            case displayName = "display_name"
            case address
            case namedetails
        }
    }
}

struct PersistedOverlays: Codable {
    let entries: [PersistedOverlayEntry]
}

struct PersistedOverlayEntry: Codable {
    let id: UUID
    let corners: [PersistedCoordinate]
    let placementCamera: PersistedMapCamera?
}

struct PersistedCoordinate: Codable {
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
}
