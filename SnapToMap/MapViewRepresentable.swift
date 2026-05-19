import CoreLocation
import MapKit
import SwiftUI
import UIKit

extension MKMapRect: @retroactive Equatable {
    public static func == (lhs: MKMapRect, rhs: MKMapRect) -> Bool {
        lhs.origin.x == rhs.origin.x &&
        lhs.origin.y == rhs.origin.y &&
        lhs.size.width == rhs.size.width &&
        lhs.size.height == rhs.size.height
    }
}

protocol MapInteractionMapViewTouchDelegate: AnyObject {
    /// At least one touch on the map (or its subviews) is in **`.began` / `.moved` / `.stationary`** — independent of **`UIGestureRecognizer.state`** gaps during rotate / multi‑touch.
    func mapInteractionMapView(_ mapView: MapInteractionMapView, directTouchesDownChanged touchesDown: Bool)
}

/// Subclass used so we can attach a zero‑delay long‑press **probe** that reports real **`UITouch`** phases. Internal map **`UIScrollView`** usually owns hit‑testing, so **`touchesBegan` on `MKMapView`** often never runs.
final class MapInteractionMapView: MKMapView, UIGestureRecognizerDelegate {
    weak var interactionTouchDelegate: MapInteractionMapViewTouchDelegate?

    let touchTrackingProbe = UILongPressGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        touchTrackingProbe.addTarget(self, action: #selector(directTouchProbeChanged(_:)))
        touchTrackingProbe.minimumPressDuration = 0
        touchTrackingProbe.cancelsTouchesInView = false
        touchTrackingProbe.delegate = self
        addGestureRecognizer(touchTrackingProbe)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func directTouchProbeChanged(_ gr: UILongPressGestureRecognizer) {
        let touchesDown: Bool
        switch gr.state {
        case .began, .changed:
            touchesDown = gr.numberOfTouches > 0
        default:
            touchesDown = false
        }
        interactionTouchDelegate?.mapInteractionMapView(self, directTouchesDownChanged: touchesDown)
    }
}

struct MapViewRepresentable: UIViewRepresentable {
    @Binding var overlays: [OverlayItem]
    var isEditing: Bool
    /// Browsing slider unfolded: map taps / pans / pinches finalize opacity and collapse the slider.
    var browsingOpacitySliderExpanded: Bool = false
    var onRequestDismissBrowsingOpacitySlider: () -> Void = {}

    @ObservedObject var bridge: MapViewBridge
    var onLongPressOverlay: (UUID) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MapInteractionMapView(frame: .zero)
        mapView.interactionTouchDelegate = context.coordinator
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
        context.coordinator.excludedManipulationTrackingGestureIds = [
            ObjectIdentifier(longPress),
            ObjectIdentifier(dismissTap),
            ObjectIdentifier(dismissPan),
            ObjectIdentifier(dismissPinch),
            ObjectIdentifier(mapView.touchTrackingProbe),
        ]
        context.coordinator.installMapInteractionTrackingIfNeeded(on: mapView)
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
        context.coordinator.installMapInteractionTrackingIfNeeded(on: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate, MapInteractionMapViewTouchDelegate {
        weak var mapBridge: MapViewBridge?

        var onLongPressOverlay: ((UUID) -> Void)?
        var onRequestDismissBrowsingOpacitySlider: (() -> Void)?
        var browsingDismissTapGesture: UITapGestureRecognizer?
        var browsingDismissPanGesture: UIPanGestureRecognizer?
        var browsingDismissPinchGesture: UIPinchGestureRecognizer?

        private var currentOverlays: [OverlayItem] = []
        private var deferredRegionSyncWorkItem: DispatchWorkItem?
        private var installedMapInteractionGestureTargets = false
        private var mapDirectManipRecognizerActiveIds = Set<ObjectIdentifier>()
        private var installedManipTargetGestureIds = Set<ObjectIdentifier>()
        var excludedManipulationTrackingGestureIds = Set<ObjectIdentifier>()

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

        func mapInteractionMapView(_ mapView: MapInteractionMapView, directTouchesDownChanged touchesDown: Bool) {
            mapBridge?.setMapManipulationFromDirectTouches(touchesDown)
        }

        /// Attaches **`mapDirectManipState`** to **all** subtree **`UIGestureRecognizer`**s (pan / pinch / rotation / etc.) except excluded app gestures. Runs on every SwiftUI update; **`installedManipTargetGestureIds`** avoids duplicate **`addTarget`**. A one-time delayed pass catches MapKit recognizers created slightly after the scroll view appears.
        func installMapInteractionTrackingIfNeeded(on mapView: MKMapView) {
            guard mapView.subviews.compactMap({ $0 as? UIScrollView }).first != nil else {
                DispatchQueue.main.async { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.installMapInteractionTrackingIfNeeded(on: mapView)
                }
                return
            }
            let sel = #selector(mapDirectManipState(_:))
            addManipTargetsRecursively(on: mapView, selector: sel)
            refreshGestureManipulationAggregate()
            if !installedMapInteractionGestureTargets {
                installedMapInteractionGestureTargets = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.addManipTargetsRecursively(on: mapView, selector: sel)
                    self.refreshGestureManipulationAggregate()
                }
            }
        }

        private func addManipTargetsRecursively(on mapView: MKMapView, selector: Selector) {
            func visit(_ view: UIView) {
                for gr in view.gestureRecognizers ?? [] {
                    let id = ObjectIdentifier(gr)
                    if excludedManipulationTrackingGestureIds.contains(id) { continue }
                    if installedManipTargetGestureIds.contains(id) { continue }
                    gr.addTarget(self, action: selector)
                    installedManipTargetGestureIds.insert(id)
                }
                for sub in view.subviews {
                    visit(sub)
                }
            }
            visit(mapView)
        }

        private func refreshGestureManipulationAggregate() {
            mapBridge?.setMapManipulationFromGestureRecognizers(!mapDirectManipRecognizerActiveIds.isEmpty)
        }

        @objc private func mapDirectManipState(_ gr: UIGestureRecognizer) {
            let id = ObjectIdentifier(gr)
            switch gr.state {
            case .began, .changed:
                mapDirectManipRecognizerActiveIds.insert(id)
            default:
                mapDirectManipRecognizerActiveIds.remove(id)
            }
            refreshGestureManipulationAggregate()
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
            let quadItems = overlays.filter { $0.corners.count == 4 }
            let cullViewport = expandedVisibleMapRectForCulling(on: mapView)
            let itemsToMount = quadItems.filter { mapRect(for: $0.corners).intersects(cullViewport) }
            SnapMemoryInstrumentation.checkpoint(
                "map.sync applySync quad=\(quadItems.count) mount=\(itemsToMount.count) tiledInMount=\(itemsToMount.filter(\.usesTiledMapPresentation).count)"
            )

            let existingRasterByID = Dictionary(uniqueKeysWithValues: mapView.overlays.compactMap { overlay -> (UUID, SnapRasterMapOverlay)? in
                guard let snap = overlay as? SnapRasterMapOverlay else { return nil }
                return (snap.overlayID, snap)
            })
            let existingMarkerByID = Dictionary(uniqueKeysWithValues: mapView.annotations.compactMap { ann -> (UUID, OverlayMarkerAnnotation)? in
                guard let marker = ann as? OverlayMarkerAnnotation else { return nil }
                return (marker.overlayID, marker)
            })

            let desiredIDs = Set(itemsToMount.map(\.id))
            let desiredRasterIDs = Set(itemsToMount.compactMap { item -> UUID? in
                let bbox = mapRect(for: item.corners)
                return shouldDisplayAsMarker(item: item, bbox: bbox, on: mapView) ? nil : item.id
            })
            let desiredMarkerIDs = desiredIDs.subtracting(desiredRasterIDs)

            for (id, existing) in existingRasterByID where !desiredRasterIDs.contains(id) {
                mapView.removeOverlay(existing)
            }
            for (id, existing) in existingMarkerByID where !desiredMarkerIDs.contains(id) {
                mapView.removeAnnotation(existing)
            }

            var anyRasterTileOnMap = false
            for item in itemsToMount {
                let bbox = mapRect(for: item.corners)
                let displayAsMarker = shouldDisplayAsMarker(item: item, bbox: bbox, on: mapView)
                if displayAsMarker {
                    if let existingOverlay = existingRasterByID[item.id] {
                        mapView.removeOverlay(existingOverlay)
                    }
                    if existingMarkerByID[item.id] == nil {
                        let coord = centerCoordinate(corners: item.corners)
                        let marker = OverlayMarkerAnnotation(overlayID: item.id, coordinate: coord)
                        mapView.addAnnotation(marker)
                    }
                    continue
                }

                anyRasterTileOnMap = true
                if let existingMarker = existingMarkerByID[item.id] {
                    mapView.removeAnnotation(existingMarker)
                }
                if let existingOverlay = existingRasterByID[item.id],
                   overlayMatches(item: item, bbox: bbox, existing: existingOverlay) {
                    continue
                }
                if let existingOverlay = existingRasterByID[item.id] {
                    mapView.removeOverlay(existingOverlay)
                }
                if item.usesTiledMapPresentation {
                    if let runtime = item.tilePyramid {
                        let root = OverlayLibrary.tilePyramidRevisionDirectoryURL(id: item.id, revision: runtime.revision)
                        let levels = OverlayLibrary.debugTilePyramidPNGCountsByZoom(pyramidRoot: root)
                        let levelSummary = levels.keys.sorted().map { "z\($0):\(levels[$0] ?? 0)" }.joined(separator: ",")
                        print("[TileDiag] map.mount id=\(item.id.uuidString.prefix(8)) tiled=true rev=\(runtime.revision) minZ=\(runtime.minimumZoom) maxZ=\(runtime.maximumZoom) rootExists=\(FileManager.default.fileExists(atPath: root.path)) levels=[\(levelSummary)]")
                    } else {
                        print("[TileDiag] map.mount id=\(item.id.uuidString.prefix(8)) tiled=true runtime=nil (lazy tile path)")
                    }
                }
                let presentation = OverlayMapPresentation.make(
                    overlayID: item.id,
                    mapDisplayImage: item.mapDisplayImage,
                    usesTiledMapPresentation: item.usesTiledMapPresentation,
                    mapBoundingRect: bbox,
                    opacityBag: rasterBag,
                    sourceRasterForTileLOD: item.sourceRasterData,
                    geographicCorners: item.corners,
                    tilePyramidRuntime: item.tilePyramid,
                    tilePyramidDiskRoot: item.tilePyramid.map {
                        OverlayLibrary.tilePyramidRevisionDirectoryURL(id: item.id, revision: $0.revision)
                    }
                )
                mapView.addOverlay(presentation.mkOverlay, level: .aboveLabels)
            }
            mapBridge?.updateRasterTileOverlayPresence(anyRasterTileOnMap)
            let snapOverlays = mapView.overlays.compactMap { $0 as? SnapRasterMapOverlay }
            let allDisplayedAreHeavyOpacity = !snapOverlays.isEmpty && snapOverlays.allSatisfy(\.presentationUsesHeavyOpacityPath)
            mapBridge?.updateDisplayedMapRastersAreAllLargeImage(allDisplayedAreHeavyOpacity)
            let bridgeRef = mapBridge
            DispatchQueue.main.async {
                bridgeRef?.applyRasterOverlayRendererAlphas()
            }
        }

        private func overlayMatches(item: OverlayItem, bbox: MKMapRect, existing: SnapRasterMapOverlay) -> Bool {
            guard existing.boundingMapRect == bbox else { return false }
            if item.usesTiledMapPresentation {
                guard let tiled = existing as? BakedImageMapTileOverlay else { return false }
                let oldSize = tiled.image.size
                let newSize = item.mapDisplayImage.size
                guard abs(oldSize.width - newSize.width) < 0.5 && abs(oldSize.height - newSize.height) < 0.5 else {
                    return false
                }
                return tiled.tilePyramidRuntimeInfo == item.tilePyramid
            } else {
                guard let raster = existing as? ImageRasterMapOverlay else { return false }
                let oldSize = raster.image.size
                let newSize = item.mapDisplayImage.size
                return abs(oldSize.width - newSize.width) < 0.5 && abs(oldSize.height - newSize.height) < 0.5
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

        /// Padded visible rect for deciding which overlays get **`MKOverlay`** / marker attachments. Avoids mounting every persisted overlay on every sync (SwiftUI often re-enters **`updateUIView`** without the map moving).
        private func expandedVisibleMapRectForCulling(on mapView: MKMapView) -> MKMapRect {
            let v = mapView.visibleMapRect
            let w = v.size.width
            let h = v.size.height
            guard w.isFinite, h.isFinite, w > 0, h > 0 else { return MKMapRect.world }
            let expansion = 0.12
            let mx = w * expansion
            let my = h * expansion
            let expanded = MKMapRect(
                origin: MKMapPoint(x: v.origin.x - mx, y: v.origin.y - my),
                size: MKMapSize(width: w + 2 * mx, height: h + 2 * my)
            )
            return expanded.intersection(MKMapRect.world)
        }

        private func shouldDisplayAsMarker(item: OverlayItem, bbox: MKMapRect, on mapView: MKMapView) -> Bool {
            let projectedCorners = item.corners.map { mapView.convert($0, toPointTo: mapView) }
            guard projectedCorners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return true }

            let bounds = projectedCorners.reduce(into: CGRect.null) { partial, point in
                partial = partial.union(CGRect(origin: point, size: .zero))
            }
            if max(bounds.width, bounds.height) < 10 {
                return true
            }

            let visibleRect = mapView.visibleMapRect
            let overlayWidth = max(bbox.width, 1)
            let overlayHeight = max(bbox.height, 1)
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
            if let tile = overlay as? BakedImageMapTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
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

        /// Fires when the user **starts** panning/zooming; **`regionDidChangeAnimated`** alone is often too late to hide the stick-to-map draft during the gesture.
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            mapBridge?.notifyMapLayoutChanged()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            mapBridge?.noteMapRegionChangedWhileWaitingForEdit()
            mapBridge?.notifyMapLayoutChanged()
            let sel = #selector(mapDirectManipState(_:))
            addManipTargetsRecursively(on: mapView, selector: sel)
            refreshGestureManipulationAggregate()
            deferSyncMapObjectsAfterRegionChange(on: mapView)
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let mapView = recognizer.view as? MKMapView else {
                return
            }
            onRequestDismissBrowsingOpacitySlider?()
            let location = recognizer.location(in: mapView)
            let overlaysTopFirst = mapView.overlays.reversed().compactMap { $0 as? SnapRasterMapOverlay }
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
