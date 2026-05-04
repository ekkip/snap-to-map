import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct MapViewRepresentable: UIViewRepresentable {
    @Binding var overlays: [OverlayItem]
    var isEditing: Bool
    /// Browsing slider unfolded: map taps / pans / pinches finalize opacity and collapse the slider.
    var browsingOpacitySliderExpanded: Bool = false
    var onRequestDismissBrowsingOpacitySlider: () -> Void = {}

    @ObservedObject var bridge: MapViewBridge
    var onLongPressOverlay: (UUID) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .none
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = !isEditing
        mapView.pointOfInterestFilter = .includingAll
        mapView.showsCompass = false
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.75
        longPress.cancelsTouchesInView = false
        mapView.addGestureRecognizer(longPress)

        let dismissTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleBrowsingDismissTap(_:)))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = context.coordinator
        mapView.addGestureRecognizer(dismissTap)
        context.coordinator.browsingDismissTapGesture = dismissTap

        let dismissPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleBrowsingDismissPan(_:)))
        dismissPan.cancelsTouchesInView = false
        dismissPan.delegate = context.coordinator
        mapView.addGestureRecognizer(dismissPan)
        context.coordinator.browsingDismissPanGesture = dismissPan

        let dismissPinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleBrowsingDismissPinch(_:)))
        dismissPinch.cancelsTouchesInView = false
        dismissPinch.delegate = context.coordinator
        mapView.addGestureRecognizer(dismissPinch)
        context.coordinator.browsingDismissPinchGesture = dismissPinch

        bridge.attach(mapView: mapView)
        context.coordinator.mapBridge = bridge
        context.coordinator.onLongPressOverlay = onLongPressOverlay
        context.coordinator.onRequestDismissBrowsingOpacitySlider = onRequestDismissBrowsingOpacitySlider
        context.coordinator.updateBrowsingDismissGesturesEnabled(browsingOpacitySliderExpanded)
        context.coordinator.syncMapObjectsFromBindingUpdate(on: mapView, overlays: overlays)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        bridge.attach(mapView: uiView)
        uiView.isPitchEnabled = !isEditing
        context.coordinator.mapBridge = bridge
        context.coordinator.onLongPressOverlay = onLongPressOverlay
        context.coordinator.onRequestDismissBrowsingOpacitySlider = onRequestDismissBrowsingOpacitySlider
        context.coordinator.updateBrowsingDismissGesturesEnabled(browsingOpacitySliderExpanded)
        context.coordinator.syncMapObjectsFromBindingUpdate(on: uiView, overlays: overlays)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var mapBridge: MapViewBridge?

        var onLongPressOverlay: ((UUID) -> Void)?
        var onRequestDismissBrowsingOpacitySlider: (() -> Void)?
        var browsingDismissTapGesture: UITapGestureRecognizer?
        var browsingDismissPanGesture: UIPanGestureRecognizer?
        var browsingDismissPinchGesture: UIPinchGestureRecognizer?

        private var currentOverlays: [OverlayItem] = []
        private var deferredRegionSyncWorkItem: DispatchWorkItem?

        func syncMapObjectsFromBindingUpdate(on mapView: MKMapView, overlays: [OverlayItem]) {
            deferredRegionSyncWorkItem?.cancel()
            deferredRegionSyncWorkItem = nil
            applySyncMapObjects(on: mapView, overlays: overlays)
        }

        private func deferSyncMapObjectsAfterRegionChange(on mapView: MKMapView) {
            deferredRegionSyncWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.applySyncMapObjects(on: mapView, overlays: self.currentOverlays)
            }
            deferredRegionSyncWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
        }

        func updateBrowsingDismissGesturesEnabled(_ enabled: Bool) {
            browsingDismissTapGesture?.isEnabled = enabled
            browsingDismissPanGesture?.isEnabled = enabled
            browsingDismissPinchGesture?.isEnabled = enabled
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleBrowsingDismissTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended else { return }
            onRequestDismissBrowsingOpacitySlider?()
        }

        @objc func handleBrowsingDismissPan(_ gr: UIPanGestureRecognizer) {
            guard gr.state == .began else { return }
            onRequestDismissBrowsingOpacitySlider?()
        }

        @objc func handleBrowsingDismissPinch(_ gr: UIPinchGestureRecognizer) {
            guard gr.state == .began else { return }
            onRequestDismissBrowsingOpacitySlider?()
        }

        func applySyncMapObjects(on mapView: MKMapView, overlays: [OverlayItem]) {
            guard let rasterBag = mapBridge?.rasterOpacity else { return }
            currentOverlays = overlays
            mapView.overlays
                .compactMap { $0 as? ImageRasterMapOverlay }
                .forEach { mapView.removeOverlay($0) }
            mapView.annotations
                .compactMap { $0 as? OverlayMarkerAnnotation }
                .forEach { mapView.removeAnnotation($0) }

            var anyRasterTileOnMap = false
            for item in overlays where item.corners.count == 4 {
                let bbox = mapRect(for: item.corners)
                let mapOverlay = ImageRasterMapOverlay(
                    overlayID: item.id,
                    image: item.sourceImage,
                    cornerCoordinates: item.corners,
                    mapBoundingRect: bbox,
                    largeImage: item.sourceImage.rasterExceedsLargeOverlayPixelThreshold,
                    opacityBag: rasterBag
                )
                if shouldDisplayAsMarker(item: item, rasterOverlay: mapOverlay, on: mapView) {
                    let coord = centerCoordinate(corners: item.corners)
                    let marker = OverlayMarkerAnnotation(overlayID: item.id, coordinate: coord)
                    mapView.addAnnotation(marker)
                } else {
                    mapView.addOverlay(mapOverlay, level: .aboveLabels)
                    anyRasterTileOnMap = true
                }
            }
            mapBridge?.updateRasterTileOverlayPresence(anyRasterTileOnMap)
            let mapRasters = mapView.overlays.compactMap { $0 as? ImageRasterMapOverlay }
            let allDisplayedAreLargeImage = !mapRasters.isEmpty && mapRasters.allSatisfy(\.largeImage)
            mapBridge?.updateDisplayedMapRastersAreAllLargeImage(allDisplayedAreLargeImage)
            let bridgeRef = mapBridge
            DispatchQueue.main.async {
                bridgeRef?.applyRasterOverlayRendererAlphas()
            }
        }

        private func centerCoordinate(corners: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
            let lats = corners.map(\.latitude)
            let lons = corners.map(\.longitude)
            return CLLocationCoordinate2D(
                latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2
            )
        }

        private func mapRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
            let points = coordinates.map { MKMapPoint($0) }
            let minX = points.map(\.x).min() ?? 0
            let maxX = points.map(\.x).max() ?? 0
            let minY = points.map(\.y).min() ?? 0
            let maxY = points.map(\.y).max() ?? 0
            return MKMapRect(
                x: minX,
                y: minY,
                width: max(maxX - minX, 1),
                height: max(maxY - minY, 1)
            )
        }

        private func shouldDisplayAsMarker(item: OverlayItem, rasterOverlay: ImageRasterMapOverlay, on mapView: MKMapView) -> Bool {
            let projectedCorners = item.corners.map { mapView.convert($0, toPointTo: mapView) }
            guard projectedCorners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return true }

            let bounds = projectedCorners.reduce(into: CGRect.null) { partial, point in
                partial = partial.union(CGRect(origin: point, size: .zero))
            }
            if max(bounds.width, bounds.height) < 10 {
                return true
            }

            let visibleRect = mapView.visibleMapRect
            let overlayWidth = max(rasterOverlay.boundingMapRect.width, 1)
            let overlayHeight = max(rasterOverlay.boundingMapRect.height, 1)
            let zoomOutFactor = max(visibleRect.width / overlayWidth, visibleRect.height / overlayHeight)

            let overlayScale = CGFloat(max(1.0, log2(max(overlayWidth, overlayHeight) / 2_000)))
            let dynamicZoomOutLimit = 20 * overlayScale
            let minVisibleSize = CGFloat(120)
            let span = max(bounds.width, bounds.height)
            let prefersMarkerZoom = zoomOutFactor >= dynamicZoomOutLimit * 0.92
            let prefersMarkerSpan = span < minVisibleSize
            return prefersMarkerZoom || prefersMarkerSpan
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let raster = overlay as? ImageRasterMapOverlay {
                return ImageRasterMapOverlayRenderer(overlay: raster)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let marker = annotation as? OverlayMarkerAnnotation else { return nil }
            let identifier = "OverlayMarker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: marker, reuseIdentifier: identifier)
            view.annotation = marker
            view.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            view.layer.cornerRadius = 8
            view.layer.backgroundColor = UIColor.systemOrange.cgColor
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 1.5
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let marker = view.annotation as? OverlayMarkerAnnotation,
                  let item = currentOverlays.first(where: { $0.id == marker.overlayID }) else {
                return
            }

            let targetRect = mapRect(for: item.corners)
            let padding = UIEdgeInsets(top: 100, left: 60, bottom: 120, right: 60)
            mapView.setVisibleMapRect(targetRect, edgePadding: padding, animated: true)
            mapView.deselectAnnotation(marker, animated: false)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            mapBridge?.noteMapRegionChangedWhileWaitingForEdit()
            deferSyncMapObjectsAfterRegionChange(on: mapView)
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let mapView = recognizer.view as? MKMapView else {
                return
            }
            onRequestDismissBrowsingOpacitySlider?()
            let location = recognizer.location(in: mapView)
            let overlaysTopFirst = mapView.overlays.compactMap { $0 as? ImageRasterMapOverlay }.reversed()
            for overlay in overlaysTopFirst {
                guard let item = currentOverlays.first(where: { $0.id == overlay.overlayID }) else { continue }
                let polygon = item.corners.map { mapView.convert($0, toPointTo: mapView) }
                if pointIsInsidePolygon(location, polygon: polygon) {
                    onLongPressOverlay?(overlay.overlayID)
                    return
                }
            }

            let markerHits = mapView.annotations.compactMap { $0 as? OverlayMarkerAnnotation }
            for marker in markerHits {
                let markerPoint = mapView.convert(marker.coordinate, toPointTo: mapView)
                if hypot(markerPoint.x - location.x, markerPoint.y - location.y) <= 20 {
                    onLongPressOverlay?(marker.overlayID)
                    return
                }
            }
        }

        private func pointIsInsidePolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
            guard polygon.count >= 3 else { return false }
            var isInside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let pi = polygon[i]
                let pj = polygon[j]
                let denominator = (pj.y - pi.y == 0) ? CGFloat.leastNonzeroMagnitude : (pj.y - pi.y)
                let intersects = ((pi.y > point.y) != (pj.y > point.y)) &&
                    (point.x < (pj.x - pi.x) * (point.y - pi.y) / denominator + pi.x)
                if intersects { isInside.toggle() }
                j = i
            }
            return isInside
        }
    }
}

/// Compass pinned in SwiftUI; **`compassVisibility`** is forced **on**, unlike built-in `MKMapView.showsCompass`.
struct MapCompassRepresentable: UIViewRepresentable {
    @ObservedObject var bridge: MapViewBridge

    func makeUIView(context: Context) -> MKCompassButton {
        let button = MKCompassButton(mapView: bridge.mapView)
        button.compassVisibility = .visible
        return button
    }

    func updateUIView(_ compass: MKCompassButton, context: Context) {
        compass.mapView = bridge.mapView
        compass.compassVisibility = .visible
    }
}
