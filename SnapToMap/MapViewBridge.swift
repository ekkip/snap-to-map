import Combine
import CoreGraphics
import CoreLocation
import MapKit

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

    private let editHandoffDebounce: TimeInterval = 0.12
    private let editHandoffRetryInterval: TimeInterval = 0.05
    private let editHandoffMaxWait: TimeInterval = 2.5
    private let editHandoffRectRelativeTolerance: Double = 0.035

    /// Expected map rect must match **`mapView.mapRectThatFits(overlayRect, edgePadding:)`** for the same **`setVisibleMapRect`** call.
    func armEditTransitionAfterMapSettles(for overlay: OverlayItem, expectedVisibleMapRect: MKMapRect) {
        cancelPendingEditFit()
        pendingFitForEditOverlay = overlay
        pendingEditExpectedVisibleMapRect = expectedVisibleMapRect
        editHandoffDeadline = Date().addingTimeInterval(editHandoffMaxWait)
    }

    /// Called from **`MKMapViewDelegate.mapView(_:regionDidChangeAnimated:)`** (and once from **`ContentView`** after **`setVisibleMapRect`**) so the handoff debounces from the **last** region delta — i.e. after the zoom animation finishes.
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
        let visible = mapView.visibleMapRect
        let matches: Bool
        if let expected = pendingEditExpectedVisibleMapRect {
            matches = Self.visibleMapRectApproximatelyEqual(visible, expected, relativeTolerance: editHandoffRectRelativeTolerance)
        } else {
            matches = true
        }

        if matches || timedOut {
            pendingFitForEditOverlay = nil
            pendingEditExpectedVisibleMapRect = nil
            editHandoffDeadline = nil
            let quad = overlay.corners.map { mapView.convert($0, toPointTo: mapView) }
            mapEditHandoff = MapEditHandoff(overlay: overlay, fittedQuadScreen: quad)
        } else {
            scheduleEditHandoffRetryPoll()
        }
    }

    private func clearPendingEditFitOnly() {
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
