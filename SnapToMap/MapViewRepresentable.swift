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
    @Binding var requestedActivationOverlayID: UUID?
    var isEditing: Bool
    /// Browsing slider unfolded: map taps / pans / pinches finalize opacity and collapse the slider.
    var browsingOpacitySliderExpanded: Bool = false
    var onRequestDismissBrowsingOpacitySlider: () -> Void = {}
    var onActivatedOverlayChanged: (UUID?) -> Void = { _ in }

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
        context.coordinator.onActivatedOverlayChanged = onActivatedOverlayChanged
        context.coordinator.updateBrowsingDismissGesturesEnabled(browsingOpacitySliderExpanded)
        context.coordinator.requestManualActivation(requestedActivationOverlayID)
        context.coordinator.syncMapObjectsFromBindingUpdate(on: mapView, overlays: overlays)
        if requestedActivationOverlayID != nil {
            DispatchQueue.main.async {
                requestedActivationOverlayID = nil
            }
        }
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
        context.coordinator.onActivatedOverlayChanged = onActivatedOverlayChanged
        context.coordinator.updateBrowsingDismissGesturesEnabled(browsingOpacitySliderExpanded)
        context.coordinator.requestManualActivation(requestedActivationOverlayID)
        context.coordinator.syncMapObjectsFromBindingUpdate(on: uiView, overlays: overlays)
        if requestedActivationOverlayID != nil {
            DispatchQueue.main.async {
                requestedActivationOverlayID = nil
            }
        }
        context.coordinator.installMapInteractionTrackingIfNeeded(on: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate, MapInteractionMapViewTouchDelegate {
        private enum AnnotationStyle {
            static let overlayMarkerReuseIdentifier = "OverlayMarker"
            static let overlayClusterReuseIdentifier = "OverlayCluster"
            static let overlayMarkerClusteringIdentifier = "OverlayMarkerCluster"
        }

        private struct OverlayMountContext {
            let item: OverlayItem
            let boundingMapRect: MKMapRect
            let polygon: [MKMapPoint]
        }

        weak var mapBridge: MapViewBridge?

        var onLongPressOverlay: ((UUID) -> Void)?
        var onRequestDismissBrowsingOpacitySlider: (() -> Void)?
        var onActivatedOverlayChanged: ((UUID?) -> Void)?
        var browsingDismissTapGesture: UITapGestureRecognizer?
        var browsingDismissPanGesture: UIPanGestureRecognizer?
        var browsingDismissPinchGesture: UIPinchGestureRecognizer?

        private var currentOverlays: [OverlayItem] = []
        private var deferredRegionSyncWorkItem: DispatchWorkItem?
        private var installedMapInteractionGestureTargets = false
        private var mapDirectManipRecognizerActiveIds = Set<ObjectIdentifier>()
        private var installedManipTargetGestureIds = Set<ObjectIdentifier>()
        var excludedManipulationTrackingGestureIds = Set<ObjectIdentifier>()
        private weak var observedMapView: MKMapView?

        /// Tiles whose disk cache was invalidated while generation is in flight; remount once when queue drains.
        private var pendingProgressiveTileUpdates: [UUID: Set<String>] = [:]
        /// Suppresses redundant scheduler viewport updates when MapKit emits micro region jitter while idle.
        private var lastSchedulerViewportRect: MKMapRect?
        private var lastSchedulerViewportZoom: Double?
        private var activeOverlayIDs = Set<UUID>()
        private var manuallyActivatedOverlayID: UUID?
        private var manualActivationNeedsFirstSync = false
        private var manualActivationIgnoresZoomUntilUserGesture = false
        private var lastNotifiedActivatedOverlayID: UUID?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleProgressiveTilesDidUpdate(_:)),
                name: .overlayProgressiveTilesDidUpdate,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleProgressiveQueueDidDrain(_:)),
                name: .overlayProgressiveTilesQueueDidDrain,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleProgressiveTilesDidUpdate(_ note: Notification) {
            guard let idString = note.userInfo?["overlayID"] as? String,
                  let overlayID = UUID(uuidString: idString) else { return }
            let z = note.userInfo?["z"] as? Int ?? -1
            let x = note.userInfo?["x"] as? Int ?? -1
            let y = note.userInfo?["y"] as? Int ?? -1
            let scale100 = note.userInfo?["scale100"] as? Int ?? -1
            let tileLabel = "z\(z)/\(x)/\(y)@\(scale100)"
            pendingProgressiveTileUpdates[overlayID, default: []].insert(tileLabel)
            print("[TileDiag] tileReady.pendingRemount id=\(overlayID.uuidString.prefix(8)) tile=\(tileLabel) batch=\(pendingProgressiveTileUpdates[overlayID]?.count ?? 0)")

            guard let mapView = observedMapView,
                  let existing = mapView.overlays.compactMap({ $0 as? BakedImageMapTileOverlay }).first(where: { $0.overlayID == overlayID }),
                  z >= 0, x >= 0, y >= 0 else { return }
            let path = MKTileOverlayPath(
                x: x,
                y: y,
                z: z,
                contentScaleFactor: CGFloat(scale100) / 100
            )
            existing.invalidateDiskCacheForTile(path: path)
        }

        @objc private func handleProgressiveQueueDidDrain(_ note: Notification) {
            guard let idString = note.userInfo?["overlayID"] as? String,
                  let overlayID = UUID(uuidString: idString),
                  let mapView = observedMapView else { return }
            let tiles = pendingProgressiveTileUpdates.removeValue(forKey: overlayID) ?? []
            guard !tiles.isEmpty else {
                print("[TileDiag] overlayRefresh.skippedEmptyBatch id=\(overlayID.uuidString.prefix(8))")
                return
            }
            print("[TileDiag] overlayRefresh.queueIdle id=\(overlayID.uuidString.prefix(8)) tiles=\(tiles.count) keys=\(tiles.sorted().prefix(8).joined(separator: ","))")
            refreshTiledOverlay(overlayID: overlayID, on: mapView)
        }

        private func refreshTiledOverlay(overlayID: UUID, on mapView: MKMapView) {
            guard let existing = mapView.overlays.compactMap({ $0 as? BakedImageMapTileOverlay }).first(where: { $0.overlayID == overlayID }) else {
                return
            }
            OverlayTileRuntimeInstrumentation.recordOverlayReload(overlayID: overlayID)
            print("[TileDiag] overlayRefresh.remount id=\(overlayID.uuidString.prefix(8))")
            mapView.removeOverlay(existing)
            mapView.addOverlay(existing, level: .aboveLabels)
            mapBridge?.applyRasterOverlayRendererAlphas()
        }

        private func notifyProgressiveSchedulerViewport(on mapView: MKMapView) {
            let visible = mapView.visibleMapRect
            let zoom = mapBridge?.currentDebugZoomLevel ?? 0
            if let lastRect = lastSchedulerViewportRect,
               let lastZoom = lastSchedulerViewportZoom,
               abs(lastZoom - zoom) < 0.08,
               relativeMapRectDelta(lastRect, visible) < 0.025 {
                return
            }
            lastSchedulerViewportRect = visible
            lastSchedulerViewportZoom = zoom
            for item in currentOverlays where item.usesTiledMapPresentation && item.tilePyramid != nil {
                OverlayTileRuntimeScheduler.shared.updateViewport(
                    overlayID: item.id,
                    visibleMapRect: visible,
                    currentZoom: zoom
                )
            }
        }

        private func relativeMapRectDelta(_ a: MKMapRect, _ b: MKMapRect) -> Double {
            let dw = max(a.size.width, b.size.width, 1)
            let dh = max(a.size.height, b.size.height, 1)
            let dx = abs(a.origin.x - b.origin.x) / dw
            let dy = abs(a.origin.y - b.origin.y) / dh
            let dww = abs(a.size.width - b.size.width) / dw
            let dhh = abs(a.size.height - b.size.height) / dh
            return max(dx, dy, dww, dhh)
        }

        private func registerProgressiveRuntimeIfNeeded(for item: OverlayItem, on mapView: MKMapView) {
            guard item.usesTiledMapPresentation,
                  let runtime = item.tilePyramid,
                  runtime.minimumZoom >= 0 else { return }
            let source = item.sourceRasterData
                ?? (item.sourceImagePreWrittenToDisk ? OverlayLibrary.persistedSourceRasterData(overlayID: item.id) : nil)
            guard let source, !source.isEmpty else { return }
            guard !OverlayLibrary.isInSaveTransition(item.id) else {
                print("[TileProg] register.deferredSaveTransition id=\(item.id.uuidString.prefix(8))")
                return
            }
            OverlayTileRuntimeScheduler.shared.startProgressiveRuntime(
                overlayID: item.id,
                revision: runtime.revision,
                corners: item.corners,
                sourceRaster: source,
                bakedFallback: item.mapDisplayImage,
                tileContentScale: OverlayLibrary.tileContentScaleForCurrentDevice(),
                visibleMapRect: mapView.visibleMapRect,
                currentZoom: mapBridge?.currentDebugZoomLevel ?? 0
            )
        }

        func syncMapObjectsFromBindingUpdate(on mapView: MKMapView, overlays: [OverlayItem]) {
            deferredRegionSyncWorkItem?.cancel()
            deferredRegionSyncWorkItem = nil
            applySyncMapObjects(on: mapView, overlays: overlays)
        }

        func requestManualActivation(_ overlayID: UUID?) {
            guard let overlayID else { return }
            manuallyActivatedOverlayID = overlayID
            manualActivationNeedsFirstSync = true
            manualActivationIgnoresZoomUntilUserGesture = true
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
            if touchesDown {
                manualActivationIgnoresZoomUntilUserGesture = false
            }
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
                manualActivationIgnoresZoomUntilUserGesture = false
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
            observedMapView = mapView
            currentOverlays = overlays
            let quadItems = overlays.filter { $0.corners.count == 4 }
            let cullViewport = expandedVisibleMapRectForCulling(on: mapView)
            let contextsToMount = quadItems.compactMap { item -> OverlayMountContext? in
                let bbox = mapRect(for: item.corners)
                guard bbox.intersects(cullViewport) else { return nil }
                return OverlayMountContext(
                    item: item,
                    boundingMapRect: bbox,
                    polygon: item.corners.map { MKMapPoint($0) }
                )
            }
            SnapMemoryInstrumentation.checkpoint(
                "map.sync applySync quad=\(quadItems.count) mount=\(contextsToMount.count) tiledInMount=\(contextsToMount.filter(\.item.usesTiledMapPresentation).count)"
            )

            let existingRasterByID = Dictionary(uniqueKeysWithValues: mapView.overlays.compactMap { overlay -> (UUID, SnapRasterMapOverlay)? in
                guard let snap = overlay as? SnapRasterMapOverlay else { return nil }
                return (snap.overlayID, snap)
            })
            let existingMarkerByID = Dictionary(uniqueKeysWithValues: mapView.annotations.compactMap { ann -> (UUID, OverlayMarkerAnnotation)? in
                guard let marker = ann as? OverlayMarkerAnnotation else { return nil }
                return (marker.overlayID, marker)
            })

            let contextByID = Dictionary(uniqueKeysWithValues: contextsToMount.map { ($0.item.id, $0) })
            let desiredIDs = Set(contextsToMount.map(\.item.id))
            let desiredRasterIDs = activatedOverlayIDs(from: contextsToMount, contextByID: contextByID, on: mapView)
            activeOverlayIDs = desiredRasterIDs
            notifyActivatedOverlayChanged(focusedActivatedOverlayID(from: desiredRasterIDs, contextByID: contextByID, on: mapView))
            let desiredMarkerIDs = desiredIDs.subtracting(desiredRasterIDs)

            for (id, existing) in existingRasterByID where !desiredRasterIDs.contains(id) {
                mapView.removeOverlay(existing)
            }
            for (id, existing) in existingMarkerByID where !desiredMarkerIDs.contains(id) {
                mapView.removeAnnotation(existing)
            }

            var anyRasterTileOnMap = false
            for context in contextsToMount {
                let item = context.item
                let bbox = context.boundingMapRect
                let shouldActivate = desiredRasterIDs.contains(item.id)
                if !shouldActivate {
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
                if item.usesTiledMapPresentation {
                    registerProgressiveRuntimeIfNeeded(for: item, on: mapView)
                }
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

        private func activatedOverlayIDs(
            from contexts: [OverlayMountContext],
            contextByID: [UUID: OverlayMountContext],
            on mapView: MKMapView
        ) -> Set<UUID> {
            let visibleMapRect = mapView.visibleMapRect
            var activeIDs = activeOverlayIDs.filter { id in
                guard let context = contextByID[id] else { return false }
                return shouldKeepActivated(context, visibleMapRect: visibleMapRect, on: mapView)
            }

            if let manualID = manuallyActivatedOverlayID {
                if let manualContext = contextByID[manualID] {
                    let manualIntersectsVisible = polygon(manualContext.polygon, intersects: visibleMapRect)
                    let shouldKeepManual = manualActivationNeedsFirstSync ||
                        (manualActivationIgnoresZoomUntilUserGesture && manualIntersectsVisible) ||
                        shouldKeepActivated(manualContext, visibleMapRect: visibleMapRect, on: mapView)
                    if shouldKeepManual {
                        activeIDs = activeIDs.filter { activeID in
                            guard let activeContext = contextByID[activeID] else { return false }
                            return activeID == manualID || !overlaysOverlap(manualContext, activeContext)
                        }
                        activeIDs.insert(manualID)
                    } else {
                        manuallyActivatedOverlayID = nil
                        manualActivationIgnoresZoomUntilUserGesture = false
                    }
                } else {
                    manuallyActivatedOverlayID = nil
                    manualActivationIgnoresZoomUntilUserGesture = false
                }
            }
            manualActivationNeedsFirstSync = false

            let autoCandidates = contexts.filter { context in
                !activeIDs.contains(context.item.id) &&
                isEligibleForAutoActivation(context, visibleMapRect: visibleMapRect, on: mapView)
            }
            let autoCandidateIDs = autoActivatedOverlayIDs(from: autoCandidates)
            for candidateID in autoCandidateIDs {
                guard let candidateContext = contextByID[candidateID] else { continue }
                let overlapsCurrentActive = activeIDs.contains { activeID in
                    guard let activeContext = contextByID[activeID] else { return false }
                    return overlaysOverlap(candidateContext, activeContext)
                }
                if !overlapsCurrentActive {
                    activeIDs.insert(candidateID)
                }
            }

            return activeIDs
        }

        private func focusedActivatedOverlayID(
            from activeIDs: Set<UUID>,
            contextByID: [UUID: OverlayMountContext],
            on mapView: MKMapView
        ) -> UUID? {
            if let manualID = manuallyActivatedOverlayID, activeIDs.contains(manualID) {
                return manualID
            }
            let mapCenter = MKMapPoint(mapView.centerCoordinate)
            return activeIDs
                .compactMap { contextByID[$0] }
                .min { lhs, rhs in
                    squaredDistance(from: mapCenter, toCenterOf: lhs.boundingMapRect) <
                        squaredDistance(from: mapCenter, toCenterOf: rhs.boundingMapRect)
                }?
                .item
                .id
        }

        private func notifyActivatedOverlayChanged(_ overlayID: UUID?) {
            guard overlayID != lastNotifiedActivatedOverlayID else { return }
            lastNotifiedActivatedOverlayID = overlayID
            DispatchQueue.main.async { [onActivatedOverlayChanged] in
                onActivatedOverlayChanged?(overlayID)
            }
        }

        private func squaredDistance(from point: MKMapPoint, toCenterOf rect: MKMapRect) -> Double {
            let x = rect.origin.x + rect.size.width / 2
            let y = rect.origin.y + rect.size.height / 2
            let dx = x - point.x
            let dy = y - point.y
            return dx * dx + dy * dy
        }

        private func isEligibleForAutoActivation(
            _ context: OverlayMountContext,
            visibleMapRect: MKMapRect,
            on mapView: MKMapView
        ) -> Bool {
            polygon(context.polygon, isFullyContainedIn: visibleMapRect) &&
            isZoomedInEnoughForActivation(item: context.item, bbox: context.boundingMapRect, on: mapView)
        }

        private func shouldKeepActivated(
            _ context: OverlayMountContext,
            visibleMapRect: MKMapRect,
            on mapView: MKMapView
        ) -> Bool {
            polygon(context.polygon, intersects: visibleMapRect) &&
            isZoomedInEnoughForActivation(item: context.item, bbox: context.boundingMapRect, on: mapView)
        }

        private func autoActivatedOverlayIDs(from candidates: [OverlayMountContext]) -> Set<UUID> {
            guard candidates.count > 1 else { return Set(candidates.map(\.item.id)) }

            var conflictedIDs = Set<UUID>()
            for index in candidates.indices {
                let nextIndex = candidates.index(after: index)
                guard nextIndex < candidates.endIndex else { continue }
                for otherIndex in nextIndex..<candidates.endIndex {
                    let lhs = candidates[index]
                    let rhs = candidates[otherIndex]
                    guard overlaysOverlap(lhs, rhs) else { continue }
                    conflictedIDs.insert(lhs.item.id)
                    conflictedIDs.insert(rhs.item.id)
                }
            }

            return Set(candidates.map(\.item.id)).subtracting(conflictedIDs)
        }

        private func overlaysOverlap(_ lhs: OverlayMountContext, _ rhs: OverlayMountContext) -> Bool {
            lhs.boundingMapRect.intersects(rhs.boundingMapRect) &&
            polygonsOverlap(lhs.polygon, rhs.polygon)
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

        private func polygonsOverlap(_ lhs: [MKMapPoint], _ rhs: [MKMapPoint]) -> Bool {
            guard lhs.count >= 3, rhs.count >= 3 else { return false }
            for lhsIndex in lhs.indices {
                let lhsNext = lhs.index(after: lhsIndex) == lhs.endIndex ? lhs.startIndex : lhs.index(after: lhsIndex)
                for rhsIndex in rhs.indices {
                    let rhsNext = rhs.index(after: rhsIndex) == rhs.endIndex ? rhs.startIndex : rhs.index(after: rhsIndex)
                    if segmentsIntersect(lhs[lhsIndex], lhs[lhsNext], rhs[rhsIndex], rhs[rhsNext]) {
                        return true
                    }
                }
            }
            return polygon(lhs, contains: rhs[0]) || polygon(rhs, contains: lhs[0])
        }

        private func segmentsIntersect(_ a: MKMapPoint, _ b: MKMapPoint, _ c: MKMapPoint, _ d: MKMapPoint) -> Bool {
            let abc = cross(a, b, c)
            let abd = cross(a, b, d)
            let cda = cross(c, d, a)
            let cdb = cross(c, d, b)

            if ((abc > 0 && abd < 0) || (abc < 0 && abd > 0)) &&
                ((cda > 0 && cdb < 0) || (cda < 0 && cdb > 0)) {
                return true
            }

            return point(c, isOnSegmentFrom: a, to: b, cross: abc) ||
                point(d, isOnSegmentFrom: a, to: b, cross: abd) ||
                point(a, isOnSegmentFrom: c, to: d, cross: cda) ||
                point(b, isOnSegmentFrom: c, to: d, cross: cdb)
        }

        private func cross(_ a: MKMapPoint, _ b: MKMapPoint, _ c: MKMapPoint) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        private func point(_ point: MKMapPoint, isOnSegmentFrom start: MKMapPoint, to end: MKMapPoint, cross: Double) -> Bool {
            guard abs(cross) < 0.000001 else { return false }
            return point.x >= min(start.x, end.x) && point.x <= max(start.x, end.x) &&
                point.y >= min(start.y, end.y) && point.y <= max(start.y, end.y)
        }

        private func polygon(_ polygon: [MKMapPoint], contains point: MKMapPoint) -> Bool {
            var isInside = false
            var previousIndex = polygon.count - 1
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[previousIndex]
                let denominator = (b.y - a.y == 0) ? Double.leastNonzeroMagnitude : (b.y - a.y)
                let intersects = ((a.y > point.y) != (b.y > point.y)) &&
                    (point.x < (b.x - a.x) * (point.y - a.y) / denominator + a.x)
                if intersects { isInside.toggle() }
                previousIndex = index
            }
            return isInside
        }

        private func polygon(_ polygon: [MKMapPoint], intersects rect: MKMapRect) -> Bool {
            guard !rect.isNull, !rect.isEmpty else { return false }
            let rectPolygon = [
                MKMapPoint(x: rect.minX, y: rect.minY),
                MKMapPoint(x: rect.maxX, y: rect.minY),
                MKMapPoint(x: rect.maxX, y: rect.maxY),
                MKMapPoint(x: rect.minX, y: rect.maxY),
            ]
            return polygonsOverlap(polygon, rectPolygon)
        }

        private func polygon(_ polygon: [MKMapPoint], isFullyContainedIn rect: MKMapRect) -> Bool {
            guard !rect.isNull, !rect.isEmpty, !polygon.isEmpty else { return false }
            return polygon.allSatisfy { point in
                point.x >= rect.minX && point.x <= rect.maxX &&
                point.y >= rect.minY && point.y <= rect.maxY
            }
        }

        private func mapRect(for markers: [OverlayMarkerAnnotation]) -> MKMapRect {
            let overlayByID = Dictionary(uniqueKeysWithValues: currentOverlays.map { ($0.id, $0) })
            return markers.reduce(MKMapRect.null) { partial, marker in
                if let item = overlayByID[marker.overlayID], item.corners.count == 4 {
                    return partial.union(mapRect(for: item.corners))
                }
                let point = MKMapPoint(marker.coordinate)
                return partial.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
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

        private func isZoomedInEnoughForActivation(item: OverlayItem, bbox: MKMapRect, on mapView: MKMapView) -> Bool {
            !shouldDisplayAsMarker(item: item, bbox: bbox, on: mapView)
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
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: AnnotationStyle.overlayClusterReuseIdentifier) ?? MKAnnotationView(
                    annotation: cluster,
                    reuseIdentifier: AnnotationStyle.overlayClusterReuseIdentifier
                )
                view.annotation = cluster
                configureClusterAnnotationView(view, count: cluster.memberAnnotations.count)
                return view
            }

            guard let marker = annotation as? OverlayMarkerAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: AnnotationStyle.overlayMarkerReuseIdentifier) ?? MKAnnotationView(
                annotation: marker,
                reuseIdentifier: AnnotationStyle.overlayMarkerReuseIdentifier
            )
            view.annotation = marker
            configureOverlayMarkerAnnotationView(view)
            return view
        }

        private func configureOverlayMarkerAnnotationView(_ view: MKAnnotationView) {
            view.frame = CGRect(x: 0, y: 0, width: 16, height: 16)
            view.layer.cornerRadius = 8
            view.layer.backgroundColor = UIColor.systemOrange.cgColor
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 1.5
            view.clusteringIdentifier = AnnotationStyle.overlayMarkerClusteringIdentifier
            view.collisionMode = .circle
            view.displayPriority = .defaultLow
            view.subviews.forEach { $0.removeFromSuperview() }
        }

        private func configureClusterAnnotationView(_ view: MKAnnotationView, count: Int) {
            view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            view.layer.cornerRadius = 16
            view.layer.backgroundColor = UIColor.systemOrange.cgColor
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.borderWidth = 2
            view.clusteringIdentifier = nil
            view.collisionMode = .circle
            view.displayPriority = .defaultHigh

            let label: UILabel
            if let existingLabel = view.subviews.compactMap({ $0 as? UILabel }).first {
                label = existingLabel
            } else {
                label = UILabel(frame: view.bounds)
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                label.textAlignment = .center
                label.textColor = .white
                label.font = .systemFont(ofSize: 14, weight: .bold)
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.65
                view.addSubview(label)
            }
            label.frame = view.bounds
            label.text = count > 99 ? "99+" : "\(count)"
            view.accessibilityLabel = "\(count) overlay markers"
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                let markers = cluster.memberAnnotations.compactMap { $0 as? OverlayMarkerAnnotation }
                let targetRect = mapRect(for: markers)
                if !targetRect.isNull, !targetRect.isEmpty {
                    let padding = UIEdgeInsets(top: 100, left: 60, bottom: 120, right: 60)
                    mapView.setVisibleMapRect(targetRect, edgePadding: padding, animated: true)
                }
                mapView.deselectAnnotation(cluster, animated: false)
                return
            }

            guard let marker = view.annotation as? OverlayMarkerAnnotation,
                  let item = currentOverlays.first(where: { $0.id == marker.overlayID }) else {
                return
            }

            let targetRect = mapRect(for: item.corners)
            let padding = UIEdgeInsets(top: 100, left: 60, bottom: 120, right: 60)
            mapView.deselectAnnotation(marker, animated: false)
            requestManualActivation(marker.overlayID)
            applySyncMapObjects(on: mapView, overlays: currentOverlays)
            mapView.setVisibleMapRect(targetRect, edgePadding: padding, animated: true)
        }

        /// Fires when the user **starts** panning/zooming; **`regionDidChangeAnimated`** alone is often too late to hide the stick-to-map draft during the gesture.
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            mapBridge?.notifyMapLayoutChanged()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            mapBridge?.noteMapRegionChangedWhileWaitingForEdit()
            mapBridge?.noteMapRegionChangedWhileWaitingForPostSave()
            mapBridge?.notifyMapLayoutChanged()
            notifyProgressiveSchedulerViewport(on: mapView)
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
