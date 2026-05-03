import CoreLocation
import UIKit

struct OverlayItem: Identifiable {
    let id: UUID
    let sourceImage: UIImage
    let corners: [CLLocationCoordinate2D]
}

struct PersistedOverlays: Codable {
    let entries: [PersistedOverlayEntry]
}

struct PersistedOverlayEntry: Codable {
    let id: UUID
    let corners: [PersistedCoordinate]
}

struct PersistedCoordinate: Codable {
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees
}
