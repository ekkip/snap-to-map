import Combine
import CoreGraphics
import CoreLocation
import MapKit

/// Shared timings for “map stopped moving” (**`editHandoff`** and stick‑to‑map draft image).
private enum MapRegionSettleTiming {
    /// Quiet period after the last region notification before starting stability polling.
    static let debounceAfterLastChange: TimeInterval = 0.12
    /// Poll interval until **two** **`MapVisualState`** samples **`isNearlyFrozen`** apart are taken.
    static let stabilityPollInterval: TimeInterval = 0.025
    static let maxWait: TimeInterval = 2.5
}

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
/// Raster overlay opacity staging: live drag applies immediately only when **`presentationUsesHeavyOpacityPath == false`** (small **`ImageRasterMapOverlay`**); tiled / large rasters use **`committed`** until the gesture ends.
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

    /// `true` when at least one overlay is drawn as a **`SnapRasterMapOverlay`** (raster or baked tile, zoomed in enough); false when all valid overlays show only **`OverlayMarkerAnnotation`** pins.
    @Published private(set) var isAnyRasterMapOverlayOnMap: Bool = false

    func updateRasterTileOverlayPresence(_ anyRasterVisible: Bool) {
        guard isAnyRasterMapOverlayOnMap != anyRasterVisible else { return }
        let value = anyRasterVisible
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAnyRasterMapOverlayOnMap != value else { return }
            self.isAnyRasterMapOverlayOnMap = value
        }
    }

    /// True when every visible **`SnapRasterMapOverlay`** uses the heavy opacity path (**`BakedImageMapTileOverlay`** or **`ImageRasterMapOverlay.largeImage`**). Drives whether browse opacity **`DragGesture.onChanged`** may repaint map tiles (false → only **`onEnded`** commits for those).
    @Published private(set) var displayedMapRastersAreAllLargeImage: Bool = false

    func updateDisplayedMapRastersAreAllLargeImage(_ allLarge: Bool) {
        guard displayedMapRastersAreAllLargeImage != allLarge else { return }
        let value = allLarge
        DispatchQueue.main.async { [weak self] in
            guard let self, self.displayedMapRastersAreAllLargeImage != value else { return }
            self.displayedMapRastersAreAllLargeImage = value
        }
    }

    /// Bumped from **`mapView(_:regionDidChangeAnimated:)`** so **`ContentView`** can re-project the draft overlay when it is anchored to the map.
    @Published private(set) var mapLayoutRevision: UInt64 = 0
    /// Debug-only current zoom level approximation derived from visible map rect.
    @Published private(set) var currentDebugZoomLevel: Double = 0

    /// Bumped after **`MapRegionSettleTiming`** debounce + **two** frozen **`MapVisualState`** samples (same idea as edit handoff) while the draft is stick‑to‑map — **`ContentView`** warps the image and fades it in.
    @Published private(set) var draftStickToMapSettledRevision: UInt64 = 0

    /// Combined “user is still physically interacting with the map” for stick‑to‑map draft hiding: **any** targeted **`UIGestureRecognizer`** in **`.began`/`.changed`** **or** the **`touchTrackingProbe`** reports fingers down ( **`UILongPressGestureRecognizer`** with **`numberOfTouches`**, not **`isDragging`** / **`isTracking`**).
    @Published private(set) var mapScrollUserGesturePhysicallyActive: Bool = false

    private var mapManipulationFromGestureRecognizers = false
    private var mapManipulationFromDirectTouches = false

    func notifyMapLayoutChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateCurrentDebugZoomLevelDeferred()
            self?.mapLayoutRevision &+= 1
        }
    }

    /// Set when **`armEditTransitionAfterMapSettles`** is waiting on region quiescence; **`ContentView`** applies and clears **`mapEditHandoff`**.
    @Published var mapEditHandoff: MapEditHandoff?

    private var mapRegionIdleWorkItem: DispatchWorkItem?
    private var pendingFitForEditOverlay: OverlayItem?
    /// Settling target from **`mapView.mapRectThatFits(_:edgePadding:)`** matching the subsequent **`setVisibleMapRect`**, so we only remove the MK overlay after the camera reaches that rect.
    private var pendingEditExpectedVisibleMapRect: MKMapRect?
    private var editHandoffDeadline: Date?

    private let editHandoffRetryInterval: TimeInterval = 0.05
    private let editHandoffRectRelativeTolerance: Double = 0.035

    /// Previous **`MapVisualState`** during stability polling; **`nil`** = next tick only seeds the baseline.
    private var editHandoffStabilityPrevious: MapVisualState?

    private var draftStickSettleIdleWorkItem: DispatchWorkItem?
    private var draftStickSettleStabilityPrevious: MapVisualState?
    private var draftStickSettleDeadline: Date?
    /// Map geometry is ready to show the draft, but **`mapScrollUserGesturePhysicallyActive`** blocked **`deliverDraftStickToMapSettled()`** — complete on touch end.
    private var draftStickSettleDeferredUntilTouchEnds: Bool = false
    /// Snapshot when deferring — **`armDraftStickToMapSettleAfterLayoutChange`** returns **`false`** if the map hasn’t moved (avoids a hide/re‑arm flash on touch-up).
    private var draftStickSettleDeferredVisualBaseline: MapVisualState?
    /// After a successful stick‑to‑map reveal, ignore **`mapLayoutRevision`** until the camera actually changes (dismisses spurious **`regionDidChange`** right after touch-up).
    private var draftStickPostRevealSpuriousArmGuardBaseline: MapVisualState?

    /// When **`expectedVisibleMapRect`** is **`nil`**, handoff waits until **`MKMapCamera`** matches **`overlay.placementCamera`** (if present), or times out.
    /// When non-**`nil`**, it must match **`mapView.mapRectThatFits(overlayRect, edgePadding:)`** for the same **`setVisibleMapRect`** used by the caller.
    func armEditTransitionAfterMapSettles(for overlay: OverlayItem, expectedVisibleMapRect: MKMapRect?) {
        cancelPendingEditFit()
        pendingFitForEditOverlay = overlay
        pendingEditExpectedVisibleMapRect = expectedVisibleMapRect
        editHandoffDeadline = Date().addingTimeInterval(MapRegionSettleTiming.maxWait)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + MapRegionSettleTiming.debounceAfterLastChange, execute: work)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + MapRegionSettleTiming.stabilityPollInterval, execute: work)
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

    /// Called from **`MapViewRepresentable`** for subtree **`UIGestureRecognizer`** **`.began`/`.changed`** (includes pan, pinch, rotation once targets are installed).
    func setMapManipulationFromGestureRecognizers(_ active: Bool) {
        guard mapManipulationFromGestureRecognizers != active else { return }
        mapManipulationFromGestureRecognizers = active
        publishCombinedMapManipulationActive()
    }

    /// Called from **`MapInteractionMapView`**’s zero‑delay touch probe so we track real **finger‑down** across gaps where **`UIGestureRecognizer.state`** is idle but touches are still on the glass.
    func setMapManipulationFromDirectTouches(_ touchesDown: Bool) {
        guard mapManipulationFromDirectTouches != touchesDown else { return }
        mapManipulationFromDirectTouches = touchesDown
        publishCombinedMapManipulationActive()
    }

    private func publishCombinedMapManipulationActive() {
        let active = mapManipulationFromGestureRecognizers || mapManipulationFromDirectTouches
        let wasActive = mapScrollUserGesturePhysicallyActive
        if !wasActive && active {
            draftStickPostRevealSpuriousArmGuardBaseline = nil
        }
        guard active != wasActive else { return }
        mapScrollUserGesturePhysicallyActive = active
        if wasActive && !active {
            tryFinishDeferredDraftStickDeliver()
        }
    }

    /// - Returns: **`true`** if this revision starts (or restarts) settle work and the draft chrome should stay hidden; **`false`** if we’re only waiting for finger-up with no camera change (no UI reset).
    @discardableResult
    func armDraftStickToMapSettleAfterLayoutChange() -> Bool {
        if let guardBaseline = draftStickPostRevealSpuriousArmGuardBaseline, let mapView {
            let now = MapVisualState(mapView)
            // Ignore **`regionDidChange`** that fires right after reveal while the camera hasn’t moved — but **not** when the user is already touching the map again; the “frozen” check would otherwise match the first **`regionWillChange`** samples of a **new** drag and block **`draftMapMotionImageOpacity = 0`** for the whole gesture.
            if guardBaseline.isNearlyFrozen(comparedTo: now), !mapScrollUserGesturePhysicallyActive {
                return false
            }
            draftStickPostRevealSpuriousArmGuardBaseline = nil
        }

        if draftStickSettleDeferredUntilTouchEnds,
           let mapView,
           let baseline = draftStickSettleDeferredVisualBaseline {
            let now = MapVisualState(mapView)
            if baseline.isNearlyFrozen(comparedTo: now) {
                return false
            }
        }
        draftStickSettleDeferredUntilTouchEnds = false
        draftStickSettleDeferredVisualBaseline = nil
        draftStickPostRevealSpuriousArmGuardBaseline = nil
        draftStickSettleDeadline = Date().addingTimeInterval(MapRegionSettleTiming.maxWait)
        scheduleDraftStickToMapDebounce()
        return true
    }

    func cancelDraftStickToMapSettle() {
        draftStickSettleIdleWorkItem?.cancel()
        draftStickSettleIdleWorkItem = nil
        draftStickSettleStabilityPrevious = nil
        draftStickSettleDeadline = nil
        draftStickSettleDeferredUntilTouchEnds = false
        draftStickSettleDeferredVisualBaseline = nil
        draftStickPostRevealSpuriousArmGuardBaseline = nil
    }

    private func scheduleDraftStickToMapDebounce() {
        draftStickSettleIdleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startDraftStickToMapStabilityPollingAfterDebounce()
        }
        draftStickSettleIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MapRegionSettleTiming.debounceAfterLastChange, execute: work)
    }

    private func startDraftStickToMapStabilityPollingAfterDebounce() {
        draftStickSettleIdleWorkItem = nil
        guard mapView != nil else {
            cancelDraftStickToMapSettle()
            return
        }
        draftStickSettleStabilityPrevious = nil
        scheduleDraftStickToMapStabilityTick()
    }

    private func scheduleDraftStickToMapStabilityTick() {
        draftStickSettleIdleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.tickDraftStickToMapStabilityPoll()
        }
        draftStickSettleIdleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MapRegionSettleTiming.stabilityPollInterval, execute: work)
    }

    private func tickDraftStickToMapStabilityPoll() {
        draftStickSettleIdleWorkItem = nil
        guard let mapView else {
            cancelDraftStickToMapSettle()
            return
        }

        if Date() >= (draftStickSettleDeadline ?? .distantFuture) {
            deliverDraftStickToMapSettled()
            return
        }

        let now = MapVisualState(mapView)
        if let prev = draftStickSettleStabilityPrevious, prev.isNearlyFrozen(comparedTo: now) {
            deliverDraftStickToMapSettled()
            return
        }

        draftStickSettleStabilityPrevious = now
        scheduleDraftStickToMapStabilityTick()
    }

    private func deliverDraftStickToMapSettled() {
        if mapScrollUserGesturePhysicallyActive {
            draftStickSettleDeferredUntilTouchEnds = true
            if let mapView {
                draftStickSettleDeferredVisualBaseline = MapVisualState(mapView)
            }
            draftStickSettleIdleWorkItem?.cancel()
            draftStickSettleIdleWorkItem = nil
            return
        }
        draftStickSettleDeferredUntilTouchEnds = false
        draftStickSettleDeferredVisualBaseline = nil
        deliverDraftStickToMapSettledConsumingState()
    }

    private func tryFinishDeferredDraftStickDeliver() {
        guard draftStickSettleDeferredUntilTouchEnds else { return }
        draftStickSettleDeferredUntilTouchEnds = false
        draftStickSettleDeferredVisualBaseline = nil
        deliverDraftStickToMapSettledConsumingState()
    }

    private func deliverDraftStickToMapSettledConsumingState() {
        draftStickSettleStabilityPrevious = nil
        draftStickSettleDeadline = nil
        draftStickSettleIdleWorkItem?.cancel()
        draftStickSettleIdleWorkItem = nil
        draftStickSettleDeferredVisualBaseline = nil
        if let mapView {
            draftStickPostRevealSpuriousArmGuardBaseline = MapVisualState(mapView)
        } else {
            draftStickPostRevealSpuriousArmGuardBaseline = nil
        }
        draftStickToMapSettledRevision &+= 1
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

    /// Updates each raster / tile overlay renderer’s **`alpha`** from **`RasterMapOpacityBag`** (per-overlay heavy-path rules). MapKit can apply this without redrawing every tile / `draw(_:)` pass.
    func applyRasterOverlayRendererAlphas() {
        guard let mapView else { return }
        for overlay in mapView.overlays {
            if let raster = overlay as? ImageRasterMapOverlay {
                guard let renderer = mapView.renderer(for: raster) else { continue }
                let alpha = raster.opacityBag?.resolvedAlpha(isLargeImage: raster.largeImage) ?? 1
                renderer.alpha = CGFloat(alpha)
            } else if let tile = overlay as? BakedImageMapTileOverlay {
                guard let renderer = mapView.renderer(for: tile) as? MKTileOverlayRenderer else { continue }
                let alpha = tile.opacityBag?.resolvedAlpha(isLargeImage: true) ?? 1
                renderer.alpha = CGFloat(alpha)
            }
        }
    }

    private let locationManager = CLLocationManager()

    func attach(mapView: MKMapView) {
        self.mapView = mapView
        self.locationManager.delegate = self
        updateCurrentDebugZoomLevelDeferred()
    }

    func zoomIn(animated: Bool = true) {
        zoomVisibleMapRect(by: 0.5, animated: animated)
    }

    func zoomOut(animated: Bool = true) {
        zoomVisibleMapRect(by: 2.0, animated: animated)
    }

    private func zoomVisibleMapRect(by factor: Double, animated: Bool) {
        guard let mapView, factor.isFinite, factor > 0 else { return }
        let visible = mapView.visibleMapRect
        guard visible.size.width > 0, visible.size.height > 0 else { return }
        let target = MKMapRect(
            x: visible.midX - (visible.size.width * factor) / 2,
            y: visible.midY - (visible.size.height * factor) / 2,
            width: visible.size.width * factor,
            height: visible.size.height * factor
        ).intersection(MKMapRect.world)
        guard !target.isNull, !target.isEmpty else { return }
        mapView.setVisibleMapRect(target, animated: animated)
    }

    private func updateCurrentDebugZoomLevelDeferred() {
        DispatchQueue.main.async { [weak self] in
            self?.updateCurrentDebugZoomLevelNow()
        }
    }

    private func updateCurrentDebugZoomLevelNow() {
        guard let mapView else { return }
        let worldWidth = max(MKMapRect.world.size.width, 1)
        let visibleWidthMapPoints = max(mapView.visibleMapRect.size.width, 1)
        let zoom = log2(worldWidth / visibleWidthMapPoints)
        guard zoom.isFinite else { return }
        if abs(currentDebugZoomLevel - zoom) > 0.0001 {
            currentDebugZoomLevel = zoom
        }
    }

    /// Ensures the system can show the user-location annotation on `MKMapView` (`showsUserLocation`).
    /// The result of the authorization request is handled asynchronously by the delegate callback.
    func requestLocationAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // Keep this non-blocking on the main thread by relying on auth status only.
            locationManager.requestWhenInUseAuthorization()
        case .restricted, .denied, .authorizedAlways, .authorizedWhenInUse:
            break
        @unknown default:
            break
        }
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
