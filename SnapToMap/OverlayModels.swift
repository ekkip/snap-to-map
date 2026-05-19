import CoreLocation
import UIKit

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
    /// Compressed source raster (**JPEG** / **HEIC** …) for **`ImageIO`** subsampled tile draws on huge overlays; avoids decoding the full bitmap while zoomed in.
    let sourceRasterData: Data?
    /// Present after **`OverlayTilePyramidBuilder`** completes; **`nil`** uses lazy **`TileCache`** rasterizing until pyramid metadata arrives from persistence reload.
    let tilePyramid: OverlayTilePyramidRuntimeInfo?

    init(
        id: UUID,
        sourceImage: UIImage,
        mapDisplayImage: UIImage,
        corners: [CLLocationCoordinate2D],
        placementCamera: PersistedMapCamera?,
        preservedSourceFileData: Data? = nil,
        sourceRasterData: Data? = nil,
        tilePyramid: OverlayTilePyramidRuntimeInfo? = nil
    ) {
        self.id = id
        self.sourceImage = sourceImage
        self.mapDisplayImage = mapDisplayImage
        let tiledPixels: Int64 = {
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

    /// Decode path for **edit** UI only — prefer **`ImageIO`** subsampling so **`CIImage`** never sees a 400 MP backing.
    func editingPreviewUIImage(maxPixelDimension: CGFloat = 8192) -> UIImage? {
        if let data = sourceRasterData, !data.isEmpty {
            return OverlayLibrary.uiImageSubsampling(from: data, maxPixelDimension: maxPixelDimension)
                ?? UIImage(data: data)
        }
        return sourceImage
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
