import Combine
import CoreGraphics
import CoreLocation
import MapKit

private func editHandoffHeadingDeltaDegrees(_ a: CLLocationDirection, _ b: CLLocationDirection) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d < 0 { d += 360 }
    return min(d, 360 - d)
}

/// Produced when **`MapViewBridge`** detects the visible map region has stabilized after a programmatic fit (`setVisibleMapRect` / animated region change).
final class MapEditHandoff {
    let overlay: OverlayItem
    /// Corners projected into view space after **`mapRegion` quiescence** so they match **`MKMapView` projection**.
    let fittedQuadScreen: [CGPoint]

    init(overlay: OverlayItem, fittedQuadScreen: [CGPoint]) {
        self.overlay = overlay
        self.fittedQuadScreen = fittedQuadScreen
    }
}
/// Raster overlay opacity staging: live drag applies immediately only when `ImageRasterMapOverlay.largeImage == false`;
/// heavyweight rasters (> 100 MP pixels) consume `committed` until the gesture ends (same repaint trade-off as stacked `MKTileOverlay` tiles).
final class RasterMapOpacityBag {
    var committed: CGFloat = 1
    var dragging: CGFloat?

    func resolvedAlpha(isLargeImage: Bool) -> CGFloat {
        let v = isLargeImage ? committed : (dragging ?? committed)
        return min(max(v, 0), 1)
    }

    func clearDragging() {
        dragging = nil
    }
}

/// Snapshot of pan/zoom/tile-relevant state for “map stopped moving” detection (edit handoff).
private struct MapVisualState {
    let visibleOriginX: Double
    let visibleOriginY: Double
    let visibleWidth: Double
    let visibleHeight: Double
    let camLat: Double
    let camLon: Double
    let camDistance: CLLocationDistance
    let camHeading: CLLocationDirection
    let camPitch: Double

    init(_ mapView: MKMapView) {
        let r = mapView.visibleMapRect
        visibleOriginX = r.origin.x
        visibleOriginY = r.origin.y
        visibleWidth = r.size.width
        visibleHeight = r.size.height
        let c = mapView.camera
        camLat = c.centerCoordinate.latitude
        camLon = c.centerCoordinate.longitude
        camDistance = c.centerCoordinateDistance
        camHeading = c.heading
        camPitch = Double(c.pitch)
    }

    /// **`true`** when two samples ~25 ms apart are effectively identical (stricter than handoff “match”).
    func isNearlyFrozen(comparedTo other: MapVisualState) -> Bool {
        let rw = max(visibleWidth, other.visibleWidth, 1)
        let rh = max(visibleHeight, other.visibleHeight, 1)
        guard abs(visibleWidth - other.visibleWidth) / rw < 0.0005,
              abs(visibleHeight - other.visibleHeight) / rh < 0.0005,
              abs(visibleOriginX - other.visibleOriginX) / rw < 0.0005,
              abs(visibleOriginY - other.visibleOriginY) / rh < 0.0005 else {
            return false
        }
        let a = CLLocation(latitude: camLat, longitude: camLon)
        let b = CLLocation(latitude: other.camLat, longitude: other.camLon)
        guard a.distance(from: b) < 0.5 else { return false }
        let dMax = max(camDistance, other.camDistance, 1)
        guard abs(camDistance - other.camDistance) / dMax < 0.0005 else { return false }
        guard editHandoffHeadingDeltaDegrees(camHeading, other.camHeading) < 0.05 else { return false }
        guard abs(camPitch - other.camPitch) < 0.05 else { return false }
        return true
    }
}

final class MapViewBridge: NSObject, ObservableObject, CLLocationManagerDelegate {
    weak var mapView: MKMapView?

    let rasterOpacity = RasterMapOpacityBag()

    /// `true` when at least one saved overlay is drawn as an **`ImageRasterMapOverlay`** (zoomed in enough); false when all valid overlays show only **`OverlayMarkerAnnotation`** pins.
    @Published private(set) var isAnyRasterMapOverlayOnMap: Bool = false

    func updateRasterTileOverlayPresence(_ anyRasterVisible: Bool) {
        if isAnyRasterMapOverlayOnMap != anyRasterVisible {
            isAnyRasterMapOverlayOnMap = anyRasterVisible
        }
    }

    /// True when the map has at least one **`ImageRasterMapOverlay`** and every one has **`largeImage == true`**. Drives whether opacity **`DragGesture.onChanged`** may repaint map tiles (false → only **`onEnded`** commits for those rasters).
    @Published private(set) var displayedMapRastersAreAllLargeImage: Bool = false

    func updateDisplayedMapRastersAreAllLargeImage(_ allLarge: Bool) {
        if displayedMapRastersAreAllLargeImage != allLarge {
            displayedMapRastersAreAllLargeImage = allLarge
        }
    }

    /// Set when **`armEditTransitionAfterMapSettles`** is waiting on region quiescence; **`ContentView`** applies and clears **`mapEditHandoff`**.
    @Published var mapEditHandoff: MapEditHandoff?

    private var mapRegionIdleWorkItem: DispatchWorkItem?
    private var pendingFitForEditOverlay: OverlayItem?
    /// Settling target from **`mapView.mapRectThatFits(_:edgePadding:)`** matching the subsequent **`setVisibleMapRect`**, so we only remove the MK overlay after the camera reaches that rect.
    private var pendingEditExpectedVisibleMapRect: MKMapRect?
    private var editHandoffDeadline: Date?

    /// Quiet period after the last **`regionDidChangeAnimated`** before we treat the map as idle.
    private let editHandoffDebounce: TimeInterval = 0.12
    /// After **`expectedFitMatches`** is true, poll this often until **two** samples **25 ms** apart report the same **`visibleMapRect` / camera** (tight epsilon) — finishes as soon as animation stops, no fixed post-delay.
    private let editHandoffStabilityPollInterval: TimeInterval = 0.025
    private let editHandoffRetryInterval: TimeInterval = 0.05
    private let editHandoffMaxWait: TimeInterval = 2.5
    private let editHandoffRectRelativeTolerance: Double = 0.035

    /// Previous **`MapVisualState`** during stability polling; **`nil`** = next tick only seeds the baseline.
    private var editHandoffStabilityPrevious: MapVisualState?

    /// When **`expectedVisibleMapRect`** is **`nil`**, handoff waits until **`MKMapCamera`** matches **`overlay.placementCamera`** (if present), or times out.
    /// When non-**`nil`**, it must match **`mapView.mapRectThatFits(overlayRect, edgePadding:)`** for the same **`setVisibleMapRect`** used by the caller.
    func armEditTransitionAfterMapSettles(for overlay: OverlayItem, expectedVisibleMapRect: MKMapRect?) {
        cancelPendingEditFit()
        pendingFitForEditOverlay = overlay
        pendingEditExpectedVisibleMapRect = expectedVisibleMapRect
        editHandoffDeadline = Date().addingTimeInterval(editHandoffMaxWait)
    }

    /// Called from **`MKMapViewDelegate.mapView(_:regionDidChangeAnimated:)`** (and once from **`ContentView`** after **`setVisibleMapRect`**) so the handoff debounces from the **last** region delta — i.e. after the zoom animation finishes.
    /// Cancels any in-flight stability poll so overlapping delegate callbacks do not complete handoff on a stale camera.
    func noteMapRegionChangedWhileWaitingForEdit() {
        guard pendingFitForEditOverlay != nil else { return }
        scheduleEditHandoffDebounce()
    }

    private func scheduleEditHandoffDebounce() {
        mapRegionIdleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluateEditHandoffIfMapMatchesExpectedFit()
        }
        mapRegionIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + editHandoffDebounce, execute: work)
    }

    private func scheduleEditHandoffRetryPoll() {
        mapRegionIdleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluateEditHandoffIfMapMatchesExpectedFit()
        }
        mapRegionIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + editHandoffRetryInterval, execute: work)
    }

    private func evaluateEditHandoffIfMapMatchesExpectedFit() {
        mapRegionIdleWorkItem = nil
        guard let overlay = pendingFitForEditOverlay, let mapView else {
            clearPendingEditFitOnly()
            return
        }

        let timedOut = Date() >= (editHandoffDeadline ?? .distantFuture)
        let matches = expectedFitMatches(mapView, overlay: overlay)

        if timedOut {
            deliverEditHandoff(overlay: overlay, mapView: mapView)
        } else if matches {
            startEditHandoffStabilityPolling()
        } else {
            editHandoffStabilityPrevious = nil
            scheduleEditHandoffRetryPoll()
        }
    }

    private func startEditHandoffStabilityPolling() {
        editHandoffStabilityPrevious = nil
        scheduleEditHandoffStabilityTick()
    }

    private func scheduleEditHandoffStabilityTick() {
        mapRegionIdleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.tickEditHandoffStabilityPoll()
        }
        mapRegionIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + editHandoffStabilityPollInterval, execute: work)
    }

    private func tickEditHandoffStabilityPoll() {
        mapRegionIdleWorkItem = nil
        guard let overlay = pendingFitForEditOverlay, let mapView else {
            editHandoffStabilityPrevious = nil
            clearPendingEditFitOnly()
            return
        }

        let timedOut = Date() >= (editHandoffDeadline ?? .distantFuture)
        if timedOut {
            editHandoffStabilityPrevious = nil
            deliverEditHandoff(overlay: overlay, mapView: mapView)
            return
        }

        let matches = expectedFitMatches(mapView, overlay: overlay)
        if !matches {
            editHandoffStabilityPrevious = nil
            scheduleEditHandoffRetryPoll()
            return
        }

        let now = MapVisualState(mapView)
        if let prev = editHandoffStabilityPrevious, prev.isNearlyFrozen(comparedTo: now) {
            editHandoffStabilityPrevious = nil
            deliverEditHandoff(overlay: overlay, mapView: mapView)
            return
        }

        editHandoffStabilityPrevious = now
        scheduleEditHandoffStabilityTick()
    }

    private func expectedFitMatches(_ mapView: MKMapView, overlay: OverlayItem) -> Bool {
        let visible = mapView.visibleMapRect
        if let expected = pendingEditExpectedVisibleMapRect {
            return Self.visibleMapRectApproximatelyEqual(visible, expected, relativeTolerance: editHandoffRectRelativeTolerance)
        } else if let saved = overlay.placementCamera {
            return Self.cameraApproximatelyMatches(mapView.camera, saved: saved)
        } else {
            return true
        }
    }

    private func deliverEditHandoff(overlay: OverlayItem, mapView: MKMapView) {
        editHandoffStabilityPrevious = nil
        pendingFitForEditOverlay = nil
        pendingEditExpectedVisibleMapRect = nil
        editHandoffDeadline = nil
        let quad = overlay.corners.map { mapView.convert($0, toPointTo: mapView) }
        mapEditHandoff = MapEditHandoff(overlay: overlay, fittedQuadScreen: quad)
    }

    private func clearPendingEditFitOnly() {
        editHandoffStabilityPrevious = nil
        pendingFitForEditOverlay = nil
        pendingEditExpectedVisibleMapRect = nil
        editHandoffDeadline = nil
    }

    private static func visibleMapRectApproximatelyEqual(_ a: MKMapRect, _ b: MKMapRect, relativeTolerance: Double) -> Bool {
        if a.isNull || b.isNull { return false }
        let tw = max(b.size.width, 1)
        let th = max(b.size.height, 1)
        let rw = abs(a.size.width - b.size.width) / tw
        let rh = abs(a.size.height - b.size.height) / th
        let acx = a.origin.x + a.size.width * 0.5
        let acy = a.origin.y + a.size.height * 0.5
        let bcx = b.origin.x + b.size.width * 0.5
        let bcy = b.origin.y + b.size.height * 0.5
        let rcx = abs(acx - bcx) / tw
        let rcy = abs(acy - bcy) / th
        return rw < relativeTolerance && rh < relativeTolerance && rcx < relativeTolerance && rcy < relativeTolerance
    }

    private static func cameraApproximatelyMatches(_ live: MKMapCamera, saved: PersistedMapCamera) -> Bool {
        let a = CLLocation(latitude: saved.centerLatitude, longitude: saved.centerLongitude)
        let b = CLLocation(latitude: live.centerCoordinate.latitude, longitude: live.centerCoordinate.longitude)
        guard a.distance(from: b) < 28 else { return false }
        guard editHandoffHeadingDeltaDegrees(live.heading, saved.heading) < 4 else { return false }
        let denom = max(saved.centerCoordinateDistance, 1)
        guard abs(live.centerCoordinateDistance - saved.centerCoordinateDistance) / denom < 0.09 else { return false }
        guard abs(Double(live.pitch) - saved.pitch) < 2.5 else { return false }
        return true
    }

    /// Updates each raster renderer’s compositing **`alpha`** from **`RasterMapOpacityBag`** (per-overlay **`largeImage` / committed / dragging** rules). MapKit applies this **without** necessarily invoking **`draw(_:zoomScale:in:)`** again, so browse-mode opacity tracks the slider smoothly (edit mode uses SwiftUI opacity on a separate layer).
    func applyRasterOverlayRendererAlphas() {
        guard let mapView else { return }
        for case let overlay as ImageRasterMapOverlay in mapView.overlays {
            guard let renderer = mapView.renderer(for: overlay) else { continue }
            let alpha = overlay.opacityBag?.resolvedAlpha(isLargeImage: overlay.largeImage) ?? 1
            renderer.alpha = CGFloat(alpha)
        }
    }

    private let locationManager = CLLocationManager()

    func attach(mapView: MKMapView) {
        self.mapView = mapView
        self.locationManager.delegate = self
    }

    /// Ensures the system can show the user-location annotation on `MKMapView` (`showsUserLocation`).
    /// The result of the authorization request is handled asynchronously by the delegate callback.
    func requestLocationAuthorizationIfNeeded() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        // Request authorization asynchronously; delegate will handle status changes.
        locationManager.requestWhenInUseAuthorization()
    }

    func centerOnUserLocation(animated: Bool = true) {
        guard let mapView else { return }
        let coord = mapView.userLocation.location?.coordinate ?? mapView.userLocation.coordinate
        guard CLLocationCoordinate2DIsValid(coord) else { return }
        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 550, longitudinalMeters: 550)
        mapView.setRegion(region, animated: animated)
    }

    func cancelPendingEditFit() {
        mapRegionIdleWorkItem?.cancel()
        mapRegionIdleWorkItem = nil
        editHandoffStabilityPrevious = nil
        pendingFitForEditOverlay = nil
        pendingEditExpectedVisibleMapRect = nil
        editHandoffDeadline = nil
        mapEditHandoff = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }
}
