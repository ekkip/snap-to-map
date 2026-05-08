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

struct OverlayItem: Identifiable {
    let id: UUID
    /// Original photo for re-edit (**«Done»** / lossless).
    let sourceImage: UIImage
    /// Mercator **bounding-box** texture used on the map in browse mode (**`OverlayMapPresentation`**: raster or tiled; see **`OverlayMapBake`**).
    let mapDisplayImage: UIImage
    /// Set once from **`sourceImage`** when the item is created. Drives **`BakedImageMapTileOverlay`** vs **`ImageRasterMapOverlay`** so map sync does not re-query rasters; also matches **`OverlayLibrary.largeRasterOverlayPixelThresholdExclusive`** (>100 MP source pixels).
    let usesTiledMapPresentation: Bool
    let corners: [CLLocationCoordinate2D]
    /// Framing at save time; when present, edit mode restores this camera instead of fitting a north-up rect.
    let placementCamera: PersistedMapCamera?
    /// Camera-roll file bytes from **`PhotosPicker`** kept only in memory for immediate editing workflows; persistence writes re-encode from `sourceImage`.
    var preservedSourceFileData: Data?

    init(
        id: UUID,
        sourceImage: UIImage,
        mapDisplayImage: UIImage,
        corners: [CLLocationCoordinate2D],
        placementCamera: PersistedMapCamera?,
        preservedSourceFileData: Data? = nil
    ) {
        self.id = id
        self.sourceImage = sourceImage
        self.mapDisplayImage = mapDisplayImage
        self.usesTiledMapPresentation = sourceImage.rasterExceedsLargeOverlayPixelThreshold
        self.corners = corners
        self.placementCamera = placementCamera
        self.preservedSourceFileData = preservedSourceFileData
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
