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
    /// Mercator **bounding-box** texture used by **`ImageRasterMapOverlay`** in browse mode (see **`OverlayMapBake`**).
    let mapDisplayImage: UIImage
    let corners: [CLLocationCoordinate2D]
    /// Framing at save time; when present, edit mode restores this camera instead of fitting a north-up rect.
    let placementCamera: PersistedMapCamera?
    /// Camera-roll file bytes from **`PhotosPicker`** when available; written to **`sourceImageData`** as-is on first save (no re-encode). Cleared after a successful disk save to limit RAM.
    var preservedSourceFileData: Data?
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
