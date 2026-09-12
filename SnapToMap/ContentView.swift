import SwiftUI
import UIKit
import MapKit
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var overlays: [OverlayItem] = []
    @State private var draftImage: UIImage?
    @State private var draftQuad: [CGPoint] = []
    @State private var initialDraftQuad: [CGPoint] = []
    @State private var editingOverlayBackup: OverlayItem?
    @State private var hasAttemptedRestore = false
    @State private var isEditing = false
    /// **`false`**: draft stays fixed in screen space while the map moves; **`true`**: draft sticks to geographic corners (2D pan/zoom/rotate only; pitch disabled in edit).
    @State private var draftAnchoredToMap = false
    /// Geographic corners matching **`draftQuad`** order (TL, TR, BR, BL); kept in sync for save and map-anchored drags.
    @State private var draftGeoCorners: [CLLocationCoordinate2D] = []
    @State private var initialDraftGeoCorners: [CLLocationCoordinate2D] = []
    /// Outside edit browsing default **1**; warp draft reflects **`draftWarpOpacityCommitted`** for large drafts while dragging.
    @State private var draftOverlayOpacityCommitted: Double = 0.5
    /// Live slider during draft drag; **`nil`** when gesture idle. Mirrors **`RasterMapOpacityBag.dragging`** for map rasters.
    @State private var draftOverlayOpacityDragging: Double?
    /// Map raster overlay opacity **when not editing** (default **1**).
    @State private var mapRasterOpacityCommitted: Double = 1
    /// Browsing-drag staging: pass **`liveDragging`** from the gesture so the bridge updates in the same run loop (SwiftUI `@State` from the binding is not updated yet when `onChanged` returns).
    @State private var mapRasterOpacityDragging: Double?
    @State private var browserOpacitySliderCollapsed: Bool = true
    @State private var activatedOverlayID: UUID?
    @State private var requestedActivationOverlayID: UUID?
    @State private var areaPanelExpanded: Bool = false
    @State private var areaPanelUnfoldedDetent: UnfoldedAreaPanelView.Detent = .basic
    @State private var areaPanelSnapshot: [OverlayItem] = []
    @Namespace private var areaPanelNamespace
    @Namespace private var browseAddNamespace
    @State private var warpedDraftCGImage: CGImage?
    @State private var primaryCTAShowsActivity: Bool = false
    /// Bytes from **`PhotosPicker`** (`Data.self`); copied into Core Data on first save without recompression.
    @State private var draftSourceFileData: Data?
    /// True when the **picked / persisted** raster exceeds **`OverlayLibrary.largeRasterOverlayPixelThresholdExclusive`** ( **`draftImage`** may be subsampled).
    @State private var draftSourceExceedsLargeOverlayThreshold = false
    /// Nested saves bump this (e.g. rapid actions); indicator stays until all complete.
    @State private var overlayPersistenceInFlight: Int = 0
    /// Coalesces back-to-back `restorePersistedOverlay()` calls (e.g. refinement + minZ notifications).
    @State private var restorePersistedOverlayToken: UInt64 = 0
    /// Debug-only current pyramid iteration z while background build is running.
    @State private var debugPyramidIterationZoomLevel: Int?
    /// Debug-only in-level progress x/L for current pyramid zoom level.
    @State private var debugPyramidIterationTileIndex: Int?
    @State private var debugPyramidIterationTileTotal: Int?
    /// Debug-only elapsed seconds in current pyramid level.
    @State private var debugPyramidIterationElapsedSeconds: Double?
    @StateObject private var mapBridge = MapViewBridge()
    private let persistence = PersistenceController.shared
    private let ciContext = CIContext()
    private let distortHandleDiameter: CGFloat = 31
    /// Edit-mode warp preview: max input side before **`CIPerspectiveTransform`** (full-res graph over 400 MP stalls the main thread).
    private let editWarpMaxSourceSide: CGFloat = 4096
    private let editWarpMaxSourceSideLargeRaster: CGFloat = 2048
    @State private var warpedDraftUpdateTask: Task<Void, Never>?
    /// Fade warped draft **image** and **corner quad** during map motion in stick-to-map mode; 50 ms each way.
    private let draftMapMotionFadeDuration: TimeInterval = 0.05
    @State private var draftMapMotionImageOpacity: Double = 1
    /// While **`true`**, **`draftWarpCacheSignature`** must not run **`updateWarpedDraftCache`** (map is moving); **`MapViewBridge`** delivers **`draftStickToMapSettledRevision`** after debounce + stability poll.
    @State private var draftMapMotionSuppressWarpUntilSettled: Bool = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                MapViewRepresentable(
                    overlays: $overlays,
                    requestedActivationOverlayID: $requestedActivationOverlayID,
                    isEditing: isEditing,
                    browsingOpacitySliderExpanded: !browserOpacitySliderCollapsed && !isEditing,
                    onRequestDismissBrowsingOpacitySlider: collapseBrowsingOpacitySliderIfNeeded,
                    onActivatedOverlayChanged: { overlayID in
                        activatedOverlayID = overlayID
                        if overlayID == nil {
                            closeAreaPanel()
                        }
                    },
                    bridge: mapBridge,
                    onLongPressOverlay: { overlayID in
                        beginEditingOverlay(id: overlayID)
                    }
                )
                .ignoresSafeArea()

                if isEditing, draftImage != nil, draftQuad.count == 4 {
                    if let warpedDraftCGImage {
                        draftOverlay(canvas: geometry.size, warped: warpedDraftCGImage)
                    }
                    editGizmos(canvas: geometry.size)
                }

            }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    closeAreaPanel()
                    updateWarpedDraftCache(canvas: geometry.size)
                } else {
                    warpedDraftCGImage = nil
                    resetDraftMapMotionFadeState()
                    draftSourceExceedsLargeOverlayThreshold = false
                }
            }
            .onChange(of: draftWarpCacheSignature(canvas: geometry.size)) { _, _ in
                guard isEditing else { return }
                if draftAnchoredToMap, draftMapMotionSuppressWarpUntilSettled { return }
                updateWarpedDraftCache(canvas: geometry.size)
            }
            .overlay(alignment: .topLeading) {
                if isEditing, editingOverlayBackup != nil {
                    chromeIconButton(icon: "trash", fontSize: 20, hitFlushAlignment: .topLeading) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        removeEditingOverlay()
                    }
                    .padding(.leading, 16)
                    .padding(.top, geometry.safeAreaInsets.top + 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    MapCompassRepresentable(bridge: mapBridge)
                        .frame(width: MapControlChrome.diameter, height: MapControlChrome.diameter)
                        .clipped()
                    chromeIconButton(icon: "location.fill", fontSize: 22, hitFlushAlignment: .trailing) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        mapBridge.centerOnUserLocation()
                    }
                    chromeIconButton(icon: "plus", fontSize: 20, hitFlushAlignment: .trailing) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        mapBridge.zoomIn()
                    }
                    chromeIconButton(icon: "minus", fontSize: 20, hitFlushAlignment: .trailing) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        mapBridge.zoomOut()
                    }
                    Text(String(format: "z %.2f", mapBridge.currentDebugZoomLevel))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .simultaneousGesture(TapGesture().onEnded { collapseBrowsingOpacitySliderIfNeeded() })
                .padding(.top, geometry.safeAreaInsets.top + 8)
                .padding(.trailing, 16)
            }
            .overlay(alignment: .bottom) {
                bottomCenterControl(bottomInset: geometry.safeAreaInsets.bottom)
            }
            .overlay(alignment: .bottom) {
                browseBottomOverlay(
                    bottomInset: geometry.safeAreaInsets.bottom,
                    canvasSize: geometry.size,
                    topInset: geometry.safeAreaInsets.top
                )
            }
            .animation(Self.browseChromeAnimation, value: areaPanelMode)
            .animation(Self.browseChromeAnimation, value: areaPanelUnfoldedDetent)
            .animation(Self.browseChromeAnimation, value: browseAddPresentation)
            .animation(.easeInOut(duration: 0.2), value: isEditing)
            .animation(.easeInOut(duration: 0.2), value: mapBridge.isAnyRasterMapOverlayOnMap)
            .onChange(of: mapBridge.isAnyRasterMapOverlayOnMap) { _, hasRaster in
                if !hasRaster, !isEditing {
                    collapseBrowsingOpacitySliderIfNeeded()
                }
            }
            .onChange(of: mapBridge.mapScrollUserGesturePhysicallyActive) { _, active in
                if active {
                    closeAreaPanel()
                }
            }
            .onChange(of: overlayPersistenceInFlight) { _, inFlight in
                if inFlight <= 0, !hasRefiningPyramids {
                    clearDebugPyramidIterationState()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                OverlayTileRuntimeScheduler.shared.handleMemoryWarning()
            }
            .onAppear {
                OverlayTileRuntimeScheduler.shared.attach(container: persistence.container)
                mapBridge.requestLocationAuthorizationIfNeeded()
                mapBridge.rasterOpacity.committed = CGFloat(min(max(mapRasterOpacityCommitted, 0), 1))
                mapBridge.rasterOpacity.clearDragging()
                mapBridge.applyRasterOverlayRendererAlphas()
                if !hasAttemptedRestore {
                    hasAttemptedRestore = true
                    OverlayLibrary.logPersistedSourceRasterPixelCounts(in: persistence.container) {
                        OverlayLibrary.resumePendingRefinements(in: persistence.container) {
                            OverlayLibrary.resumeMissingInitialPyramidBuilds(in: persistence.container) {
                                OverlayLibrary.resumeUnderestimatedPyramidCeilings(in: persistence.container) {
                                    restorePersistedOverlay()
                                }
                            }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayTilePyramidIterationDidChange)) { note in
                if (note.userInfo?[OverlayTilePyramidBuilder.debugIterationResetKey] as? Bool) == true {
                    clearDebugPyramidIterationState()
                }
                let finished = (note.userInfo?[OverlayTilePyramidBuilder.debugIterationFinishedKey] as? Bool) ?? false
                if finished {
                    clearDebugPyramidIterationState()
                    return
                }
                if let z = note.userInfo?[OverlayTilePyramidBuilder.debugIterationZoomLevelKey] as? Int {
                    debugPyramidIterationZoomLevel = z
                }
                if let x = note.userInfo?[OverlayTilePyramidBuilder.debugIterationLevelTileIndexKey] as? Int {
                    debugPyramidIterationTileIndex = x
                }
                if let total = note.userInfo?[OverlayTilePyramidBuilder.debugIterationLevelTileTotalKey] as? Int {
                    debugPyramidIterationTileTotal = total
                }
                if let elapsed = note.userInfo?[OverlayTilePyramidBuilder.debugIterationElapsedSecondsKey] as? Double {
                    debugPyramidIterationElapsedSeconds = elapsed
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayTilePyramidRefinementDidComplete)) { _ in
                restorePersistedOverlay()
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayTilePyramidMinZReady)) { note in
                guard let idString = note.userInfo?["overlayID"] as? String,
                      let id = UUID(uuidString: idString),
                      let mapView = mapBridge.mapView else { return }
                loadOverlaysFromStoreSync()
                guard let item = overlays.first(where: { $0.id == id }) else { return }
                OverlaySaveTransitionLog.stage("overlay.displayed", overlayID: id)
                let targetRect = mapRect(for: item.corners)
                let padding = UIEdgeInsets(top: 100, left: 50, bottom: 120, right: 50)
                let expectedVisible = mapView.mapRectThatFits(targetRect, edgePadding: padding)
                mapView.setVisibleMapRect(targetRect, edgePadding: padding, animated: true)
                mapBridge.armPostSavePrewarmAfterZoomSettles(overlayID: id, expectedVisibleMapRect: expectedVisible)
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlaySaveTransitionZoomDidSettle)) { note in
                guard let idString = note.userInfo?["overlayID"] as? String,
                      let id = UUID(uuidString: idString),
                      let mapView = mapBridge.mapView else { return }
                OverlayLibrary.enablePrewarmAfterSaveZoomSettled(
                    overlayID: id,
                    container: persistence.container,
                    visibleMapRect: mapView.visibleMapRect,
                    currentZoom: mapBridge.currentDebugZoomLevel
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayProgressiveTilesDidUpdate)) { _ in
                // Overlay remount handled in MapViewRepresentable; reload model if Core Data row changed.
            }
            .onChange(of: mapRasterOpacityCommitted) { _, _ in
                if !isEditing, mapRasterOpacityDragging == nil {
                    browsingRasterOpacitySyncBagAndRedraw()
                }
            }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await loadImage(from: newItem, canvas: geometry.size)
                }
            }
            .onChange(of: mapBridge.draftStickToMapSettledRevision) { _, _ in
                guard isEditing, draftAnchoredToMap, draftImage != nil, draftQuad.count == 4 else { return }
                syncDraftQuadFromGeo(canvas: geometry.size)
                draftMapMotionSuppressWarpUntilSettled = false
                updateWarpedDraftCache(canvas: geometry.size)
                draftMapMotionImageOpacity = 1
            }
            .onChange(of: mapBridge.mapEditHandoff?.overlay.id) { _, _ in
                guard let handoff = mapBridge.mapEditHandoff else { return }
                mapBridge.mapEditHandoff = nil
                applyMapEditTransition(handoff, canvas: geometry.size)
            }
            .onChange(of: mapBridge.mapLayoutRevision) { _, _ in
                guard isEditing, draftImage != nil, draftQuad.count == 4 else { return }
                if draftGeoCorners.count != 4 {
                    syncDraftGeoFromScreenQuad(canvas: geometry.size)
                    if initialDraftGeoCorners.count != 4 {
                        initialDraftGeoCorners = draftGeoCorners
                    }
                } else if draftAnchoredToMap {
                    syncDraftQuadFromGeo(canvas: geometry.size)
                } else {
                    syncDraftGeoFromScreenQuad(canvas: geometry.size)
                }
                if draftAnchoredToMap {
                    let shouldRestartSettling = mapBridge.armDraftStickToMapSettleAfterLayoutChange()
                    if shouldRestartSettling {
                        draftMapMotionSuppressWarpUntilSettled = true
                        draftMapMotionImageOpacity = 0
                    }
                } else {
                    updateWarpedDraftCache(canvas: geometry.size)
                }
            }
            /// Bottom overlays anchor to the physical scene bottom; `safeAreaInsets.bottom` padding lifts them once (~34 pt on home-indicator iPhones). Without this, SwiftUI already insets to the safe area and the padding stacks (~68 pt).
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    /// Center: edit-mode Done only (`BrowseAddControl` handles browse add).
    @ViewBuilder
    private func bottomCenterControl(bottomInset: CGFloat) -> some View {
        if isEditing {
            let d = MapControlChrome.bottomBaseDimension
            let tap = d + 2
            ZStack(alignment: .bottom) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: tap, height: tap)
                    .contentShape(Circle())
                if primaryCTAShowsActivity {
                    MapControlChrome.circularControl(.primaryCTA, diameter: d) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                } else {
                    MapControlChrome.primaryCTAButton(icon: "checkmark", fontSize: 22, diameter: d) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        saveDraftAsOverlay()
                    }
                }
            }
            .frame(width: tap, height: tap, alignment: .bottom)
            .padding(.bottom, bottomInset)
        }
    }

    /// Unfolded browse area panel, description name row, or leading symbol launcher.
    private enum AreaPanelMode: Equatable {
        case hidden
        case symbol
        case description(name: String, overlayID: UUID)
        case unfolded
    }

    private var areaPanelMode: AreaPanelMode {
        if isEditing { return .hidden }
        if areaPanelExpanded { return .unfolded }
        if mapBridge.isAnyRasterMapOverlayOnMap, let active = activatedOverlay {
            return .description(name: active.resolvedDisplayName, overlayID: active.id)
        }
        if !overlays.isEmpty,
           !mapBridge.isAnyRasterMapOverlayOnMap,
           !visibleAreaOverlaysSorted().isEmpty {
            return .symbol
        }
        return .hidden
    }

    /// Centered labeled pill vs trailing icon-only add.
    private enum BrowseAddPresentation: Equatable {
        case hidden
        case labeled
        case iconOnly
    }

    private var browseAddPresentation: BrowseAddPresentation {
        if isEditing { return .hidden }
        if mapBridge.isAnyRasterMapOverlayOnMap { return .iconOnly }
        return .labeled
    }

    private static let browseChromeAnimation = Animation.easeInOut(duration: 0.28)

    private func centeredBrowseAddMaxWidth(canvasWidth: CGFloat) -> CGFloat {
        let reservedLeading: CGFloat
        if case .symbol = areaPanelMode {
            reservedLeading = MapControlChrome.bottomHorizontalInset
                + MapControlChrome.bottomBaseDimension
                + MapControlChrome.bottomAdjacentControlGap
        } else {
            reservedLeading = MapControlChrome.bottomHorizontalInset
        }
        return canvasWidth - reservedLeading - MapControlChrome.bottomHorizontalInset
    }

    @ViewBuilder
    private func browseBottomOverlay(bottomInset: CGFloat, canvasSize: CGSize, topInset: CGFloat) -> some View {
        let canvasWidth = canvasSize.width
        ZStack(alignment: .bottom) {
            if !areaPanelExpanded {
                HStack(alignment: .bottom, spacing: MapControlChrome.bottomAdjacentControlGap) {
                    if isEditing || mapBridge.isAnyRasterMapOverlayOnMap {
                        OverlayOpacitySlider(
                            isEditing: isEditing,
                            browserCollapsed: $browserOpacitySliderCollapsed,
                            draftOpacityCommitted: $draftOverlayOpacityCommitted,
                            draftOpacityDragging: $draftOverlayOpacityDragging,
                            finalizeDraftDraggingIntoCommitted: finalizeDraftRasterOpacityGestureEnd,
                            mapOpacityCommitted: $mapRasterOpacityCommitted,
                            mapOpacityLive: $mapRasterOpacityDragging,
                            redrawBrowsingMapRaster: { alpha in
                                browsingRasterOpacitySyncBagAndRedraw(liveDragging: alpha, duringLiveDragOnChanged: true)
                            },
                            finalizeBrowsingOpacity: finalizeBrowsingRasterOpacityInteraction
                        )
                    } else if areaPanelMode == .symbol {
                        symbolCollapsedAreaPanel(bottomInset: 0)
                    }

                    if case .description(let name, let overlayID) = areaPanelMode {
                        descriptionCollapsedAreaPanel(name: name, overlayID: overlayID, bottomInset: 0)
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }

                    if browseAddPresentation == .iconOnly {
                        browseAddControl(
                            bottomInset: 0,
                            canvasWidth: canvasWidth,
                            presentation: .iconOnly
                        )
                    }

                    bottomTrailingChromeStack(canvas: CGSize(width: canvasWidth, height: 0))
                }
                .padding(.horizontal, MapControlChrome.bottomHorizontalInset)
                .padding(.bottom, bottomInset)
                .zIndex(1)

                if browseAddPresentation == .labeled {
                    browseAddControl(
                        bottomInset: bottomInset,
                        canvasWidth: canvasWidth,
                        presentation: .labeled
                    )
                    .zIndex(1)
                }
            }

            if !isEditing, areaPanelExpanded {
                UnfoldedAreaPanelView(
                    items: areaPanelSnapshot.isEmpty ? visibleAreaOverlaysSorted() : areaPanelSnapshot,
                    screenSize: canvasSize,
                    topSafeInset: topInset,
                    bottomSafeInset: bottomInset,
                    detent: $areaPanelUnfoldedDetent,
                    activatedOverlayID: activatedOverlayID,
                    namespace: areaPanelNamespace,
                    onActivate: activateAreaOverlay,
                    onCollapseToDescription: collapseAreaPanelToDescription
                )
                .frame(maxWidth: .infinity, alignment: .bottom)
                .zIndex(10)
            }
        }
    }

    @ViewBuilder
    private func browseAddControl(
        bottomInset: CGFloat,
        canvasWidth: CGFloat,
        presentation: BrowseAddControl.Presentation
    ) -> some View {
        BrowseAddControl(
            presentation: presentation,
            maxLabelWidth: centeredBrowseAddMaxWidth(canvasWidth: canvasWidth),
            bottomInset: bottomInset,
            selectedItem: $selectedItem,
            namespace: browseAddNamespace,
            onInteraction: {
                collapseBrowsingOpacitySliderIfNeeded()
                closeAreaPanel()
            }
        )
    }

    /// Bottom-trailing: persistence spinner, then reset-distort above cancel when editing.
    @ViewBuilder
    private func bottomTrailingChromeStack(canvas: CGSize) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            let shouldShowSyncIndicator = hasRefiningPyramids || overlayPersistenceInFlight > 0
            if shouldShowSyncIndicator {
                overlayPersistenceSavingIndicator
            }
            if isEditing {
                if hasCornerEdits {
                    chromeIconButton(icon: "arrow.counterclockwise", fontSize: 20, hitFlushAlignment: .trailing) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        resetDraftQuad(for: canvas)
                    }
                }
                chromeIconButton(icon: draftAnchoredToMap ? "lock.fill" : "lock.open.fill", fontSize: 20, hitFlushAlignment: .trailing) {
                    collapseBrowsingOpacitySliderIfNeeded()
                    draftAnchoredToMap.toggle()
                    if !draftAnchoredToMap {
                        cancelDraftMapMotionSettledDebounce()
                        resetDraftMapMotionFadeState()
                    }
                    if draftAnchoredToMap {
                        syncDraftGeoFromScreenQuad(canvas: canvas)
                        syncDraftQuadFromGeo(canvas: canvas)
                    } else {
                        syncDraftQuadFromGeo(canvas: canvas)
                    }
                    updateWarpedDraftCache(canvas: canvas)
                }
                chromeIconButton(icon: "xmark", fontSize: 20, hitFlushAlignment: .trailing) {
                    collapseBrowsingOpacitySliderIfNeeded()
                    cancelEditing()
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { collapseBrowsingOpacitySliderIfNeeded() })
    }

    private var activatedOverlay: OverlayItem? {
        guard let activatedOverlayID else { return nil }
        return overlays.first { $0.id == activatedOverlayID }
    }

    private func symbolCollapsedAreaPanel(bottomInset: CGFloat) -> some View {
        Button {
            openAreaPanel()
        } label: {
            MapControlChrome.circularControl(.standard, diameter: MapControlChrome.bottomBaseDimension) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .matchedGeometryEffect(id: "areaPanelSurface", in: areaPanelNamespace)
        }
        .buttonStyle(.plain)
        .padding(.bottom, bottomInset)
    }

    private func descriptionCollapsedAreaPanel(name: String, overlayID: UUID, bottomInset: CGFloat) -> some View {
        let cornerRadius = MapControlChrome.bottomBaseDimension / 2
        return ZStack(alignment: .top) {
            areaPanelBackground(cornerRadius: cornerRadius)
                .matchedGeometryEffect(id: "areaPanelSurface", in: areaPanelNamespace)
            areaPanelGrabber
                .matchedGeometryEffect(id: "areaPanelGrabber", in: areaPanelNamespace)
                .padding(.top, 7)
            Text(name)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .animation(Self.browseChromeAnimation, value: overlayID)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MapControlChrome.bottomBaseDimension)
        .padding(.bottom, bottomInset)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture {
            openAreaPanel()
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if value.translation.height < -12 {
                        openAreaPanel()
                    }
                }
        )
    }

    private var areaPanelGrabber: some View {
        Capsule()
            .fill(Color.primary.opacity(0.35))
            .frame(width: 40, height: 4)
    }

    @ViewBuilder
    private func areaPanelBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            shape
                .fill(Color.clear)
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        }
    }

    private func openAreaPanel() {
        guard !isEditing else { return }
        collapseBrowsingOpacitySliderIfNeeded()
        let visible = visibleAreaOverlaysSorted()
        withAnimation(Self.browseChromeAnimation) {
            areaPanelSnapshot = visible.isEmpty ? activatedOverlay.map { [$0] } ?? [] : visible
            areaPanelUnfoldedDetent = .basic
            areaPanelExpanded = true
        }
    }

    private func collapseAreaPanelToDescription() {
        guard areaPanelExpanded else { return }
        withAnimation(Self.browseChromeAnimation) {
            areaPanelExpanded = false
            areaPanelUnfoldedDetent = .basic
        }
    }

    private func closeAreaPanel() {
        guard areaPanelExpanded || !areaPanelSnapshot.isEmpty else { return }
        withAnimation(Self.browseChromeAnimation) {
            areaPanelExpanded = false
            areaPanelUnfoldedDetent = .basic
            areaPanelSnapshot = []
        }
    }

    private func activateAreaOverlay(_ item: OverlayItem) {
        guard !isEditing else { return }
        collapseBrowsingOpacitySliderIfNeeded()
        withAnimation(Self.browseChromeAnimation) {
            activatedOverlayID = item.id
            requestedActivationOverlayID = item.id
            areaPanelExpanded = false
            areaPanelUnfoldedDetent = .basic
        }
        zoomToOverlay(item)
    }

    private func zoomToOverlay(_ item: OverlayItem) {
        guard let mapView = mapBridge.mapView else { return }
        let targetRect = mapRect(for: item.corners)
        let padding = UIEdgeInsets(top: 100, left: 60, bottom: 310, right: 60)
        mapView.setVisibleMapRect(targetRect, edgePadding: padding, animated: true)
    }

    private static let areaQueryMinimumExpansionMeters: CLLocationDistance = 2_000
    private static let areaQueryShortSideExpansionFraction: Double = 0.5

    /// Visible viewport expanded by max(2 km, 50% of its short side) for the "This area" panel.
    private func areaQueryMapRect(for mapView: MKMapView) -> MKMapRect {
        let visible = mapView.visibleMapRect
        let width = visible.size.width
        let height = visible.size.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return visible }

        let centerLatitude = MKMapPoint(x: visible.midX, y: visible.midY).coordinate.latitude
        let minimumExpansion = Self.areaQueryMinimumExpansionMeters * MKMapPointsPerMeterAtLatitude(centerLatitude)
        let halfShortSide = Self.areaQueryShortSideExpansionFraction * min(width, height)
        let expansion = max(minimumExpansion, halfShortSide)

        let expanded = MKMapRect(
            origin: MKMapPoint(x: visible.origin.x - expansion, y: visible.origin.y - expansion),
            size: MKMapSize(width: width + 2 * expansion, height: height + 2 * expansion)
        )
        return expanded.intersection(MKMapRect.world)
    }

    private func visibleAreaOverlaysSorted() -> [OverlayItem] {
        guard let mapView = mapBridge.mapView else { return overlays }
        let areaQuery = areaQueryMapRect(for: mapView)
        let filtered = overlays.filter { item in
            guard item.corners.count == 4 else { return false }
            return mapRect(for: item.corners).intersects(areaQuery)
        }
        let sorted = filtered.sorted { lhs, rhs in
            overlayDistanceSort(lhs, rhs, mapView: mapView)
        }
        return areaOverlaysWithActiveFirst(sorted)
    }

    private func areaOverlaysWithActiveFirst(_ items: [OverlayItem]) -> [OverlayItem] {
        guard let activatedOverlayID else { return items }
        guard let activeIndex = items.firstIndex(where: { $0.id == activatedOverlayID }) else { return items }
        var reordered = items
        let active = reordered.remove(at: activeIndex)
        reordered.insert(active, at: 0)
        return reordered
    }

    private func overlayDistanceSort(_ lhs: OverlayItem, _ rhs: OverlayItem, mapView: MKMapView) -> Bool {
        let center = MKMapPoint(mapView.centerCoordinate)
        return squaredDistance(from: center, toCenterOf: lhs.corners) <
            squaredDistance(from: center, toCenterOf: rhs.corners)
    }

    private func squaredDistance(from point: MKMapPoint, toCenterOf corners: [CLLocationCoordinate2D]) -> Double {
        let rect = mapRect(for: corners)
        let x = rect.origin.x + rect.size.width / 2
        let y = rect.origin.y + rect.size.height / 2
        let dx = x - point.x
        let dy = y - point.y
        return dx * dx + dy * dy
    }

    private var overlayPersistenceSavingIndicator: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let z = debugPyramidIterationZoomLevel {
                let progressLabel: String = {
                    let elapsedSuffix: String = {
                        guard let elapsed = debugPyramidIterationElapsedSeconds else { return "" }
                        return String(format: " %.1fs", elapsed)
                    }()
                    if let x = debugPyramidIterationTileIndex, let total = debugPyramidIterationTileTotal, total > 0 {
                        return "Build z\(z)\n\(x)/\(total)\(elapsedSuffix)"
                    }
                    return "Build z\(z)\n\(elapsedSuffix)"
                }()
                Text(progressLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let degrees = (context.date.timeIntervalSinceReferenceDate * (360.0 / 1.35)).truncatingRemainder(dividingBy: 360)
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .rotationEffect(.degrees(degrees))
                    .accessibilityLabel("Saving")
            }
        }
    }

    private func clearDebugPyramidIterationState() {
        debugPyramidIterationZoomLevel = nil
        debugPyramidIterationTileIndex = nil
        debugPyramidIterationTileTotal = nil
        debugPyramidIterationElapsedSeconds = nil
    }

    private var hasRefiningPyramids: Bool {
        overlays.contains { item in
            item.tilePyramid?.refinementInProgress == true
                || (item.usesTiledMapPresentation && item.tilePyramid == nil)
        }
    }

    /// **`hitFlushAlignment`** pins the **46** pt glass flush to that corner of the **`diameter+2`** tap cell so margins match **`MapControlChrome.diameter`** neighbours (compass / opacity); the extra **1 pt** ring is **inward** only.
    private func chromeIconButton(icon: String, fontSize: CGFloat, hitFlushAlignment: Alignment, action: @escaping () -> Void) -> some View {
        let tap = MapControlChrome.diameter + 2
        return Button(action: action) {
            ZStack(alignment: hitFlushAlignment) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: tap, height: tap)
                    .contentShape(Circle())
                MapControlChrome.circularControl(.standard) {
                    Image(systemName: icon)
                        .font(.system(size: fontSize, weight: .regular))
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func draftOverlay(canvas: CGSize, warped: CGImage) -> some View {
        Image(decorative: warped, scale: 1, orientation: .up)
            .resizable()
            .frame(width: canvas.width, height: canvas.height)
            .opacity(draftWarpDisplayOpacity * draftMapMotionImageOpacity)
            .animation(.linear(duration: draftMapMotionFadeDuration), value: draftMapMotionImageOpacity)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private func draftWarpCacheSignature(canvas: CGSize) -> String {
        guard let img = draftImage else { return "_" }
        let oid = ObjectIdentifier(img as AnyObject)
        let mode = draftAnchoredToMap ? "m" : "s"
        let q = draftQuad.map { String(format: "%.2f,%.2f", $0.x, $0.y) }.joined(separator: "|")
        return "\(oid)|\(mode)|\(Int(canvas.width))x\(Int(canvas.height))|\(q)"
    }

    private func updateWarpedDraftCache(canvas: CGSize) {
        warpedDraftUpdateTask?.cancel()
        guard isEditing, let image = draftImage, draftQuad.count == 4, canvas.width > 1, canvas.height > 1 else {
            warpedDraftCGImage = nil
            return
        }
        let quad = draftQuad
        let useLargeRasterCap = draftSourceExceedsLargeOverlayThreshold
        warpedDraftUpdateTask = Task {
            let warped = await Task.detached(priority: .userInitiated) {
                Self.warpedDraftCGImage(for: image, size: canvas, quad: quad, largeRaster: useLargeRasterCap)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                warpedDraftCGImage = warped
            }
        }
    }

    private func editGizmos(canvas: CGSize) -> some View {
        ZStack {
            Path { path in
                path.move(to: draftQuad[0])
                path.addLine(to: draftQuad[1])
                path.addLine(to: draftQuad[2])
                path.addLine(to: draftQuad[3])
                path.closeSubpath()
            }
            .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            /// The quad’s **axis‑aligned bounds** otherwise steal taps (e.g. near bottom‑trailing HUD); only corner **`Circle`** handles need hits.
            .allowsHitTesting(false)

            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(.white)
                    .frame(width: distortHandleDiameter, height: distortHandleDiameter)
                    .overlay {
                        Circle().stroke(.blue, lineWidth: 3)
                    }
                    .position(draftQuad[index])
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                handleDraftCornerDrag(index: index, location: value.location, canvas: canvas)
                            }
                    )
            }
        }
        .opacity(draftWarpDisplayOpacity * draftMapMotionImageOpacity)
        .animation(.linear(duration: draftMapMotionFadeDuration), value: draftMapMotionImageOpacity)
        .allowsHitTesting(draftMapMotionImageOpacity > 0.01)
        .ignoresSafeArea()
    }

    private var draftWarpDisplayOpacity: Double {
        guard let draftImage else { return 1 }
        let v = draftSourceExceedsLargeOverlayThreshold
            ? draftOverlayOpacityCommitted
            : (draftOverlayOpacityDragging ?? draftOverlayOpacityCommitted)
        return min(max(v, 0), 1)
    }

    private func finalizeDraftRasterOpacityGestureEnd() {
        let merged = min(max(draftOverlayOpacityDragging ?? draftOverlayOpacityCommitted, 0), 1)
        draftOverlayOpacityCommitted = merged
        draftOverlayOpacityDragging = nil
    }

    private var hasCornerEdits: Bool {
        if draftAnchoredToMap {
            guard draftGeoCorners.count == 4, initialDraftGeoCorners.count == 4 else { return false }
            return zip(draftGeoCorners, initialDraftGeoCorners).contains { a, b in
                CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) > 1.5
            }
        }
        guard draftQuad.count == 4, initialDraftQuad.count == 4 else { return false }
        return zip(draftQuad, initialDraftQuad).contains { lhs, rhs in
            hypot(lhs.x - rhs.x, lhs.y - rhs.y) > 0.5
        }
    }

    private func loadImage(from item: PhotosPickerItem, canvas: CGSize) async {
        await MainActor.run { primaryCTAShowsActivity = true }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run { primaryCTAShowsActivity = false }
                return
            }

            let loadedUIImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let px = UIImage.rasterPixelCount(forCompressedImageData: data)
                if let px, px > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive {
                    return OverlayLibrary.uiImageSubsampling(from: data, maxPixelDimension: 8192)
                }
                return UIImage(data: data)
            }.value

            guard let image = loadedUIImage else {
                await MainActor.run { primaryCTAShowsActivity = false }
                return
            }

            await MainActor.run {
                mapBridge.cancelPendingEditFit()
                draftSourceExceedsLargeOverlayThreshold = (UIImage.rasterPixelCount(forCompressedImageData: data) ?? 0) > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive
                draftImage = image
                draftSourceFileData = data
                draftAnchoredToMap = false
                draftGeoCorners = []
                initialDraftGeoCorners = []
                resetDraftMapMotionFadeState()
                draftOverlayOpacityCommitted = 0.5
                draftOverlayOpacityDragging = nil
                browserOpacitySliderCollapsed = false
                resetDraftQuad(for: canvas)
                editingOverlayBackup = nil
                isEditing = true
                updateWarpedDraftCache(canvas: canvas)
                primaryCTAShowsActivity = false
            }
        } catch {
            await MainActor.run { primaryCTAShowsActivity = false }
        }
    }

    private func resetDraftQuad(for size: CGSize) {
        let imageSize = draftImage?.size ?? CGSize(width: 1, height: 1)
        let aspect = max(imageSize.width / max(imageSize.height, 1), 0.01)
        let maxWidth = size.width * 0.72
        let maxHeight = size.height * 0.58
        let width: CGFloat
        let height: CGFloat
        if maxWidth / maxHeight > aspect {
            height = maxHeight
            width = height * aspect
        } else {
            width = maxWidth
            height = width / aspect
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        let topLeft = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        let topRight = CGPoint(x: center.x + width / 2, y: center.y - height / 2)
        let bottomRight = CGPoint(x: center.x + width / 2, y: center.y + height / 2)
        let bottomLeft = CGPoint(x: center.x - width / 2, y: center.y + height / 2)
        draftQuad = [topLeft, topRight, bottomRight, bottomLeft]
        initialDraftQuad = draftQuad
        syncDraftGeoFromScreenQuad(canvas: size)
        initialDraftGeoCorners = draftGeoCorners
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), size.width),
            y: min(max(point.y, 0), size.height)
        )
    }

    private func syncDraftGeoFromScreenQuad(canvas: CGSize) {
        guard let mapView = mapBridge.mapView, draftQuad.count == 4 else { return }
        draftGeoCorners = draftQuad.map { mapView.convert($0, toCoordinateFrom: mapView) }
    }

    private func syncDraftQuadFromGeo(canvas: CGSize) {
        guard let mapView = mapBridge.mapView, draftGeoCorners.count == 4 else { return }
        draftQuad = draftGeoCorners.map { mapView.convert($0, toPointTo: mapView) }
    }

    private func handleDraftCornerDrag(index: Int, location: CGPoint, canvas: CGSize) {
        if draftAnchoredToMap {
            cancelDraftMapMotionSettledDebounce()
            draftMapMotionImageOpacity = 1
        }
        let p = clamp(location, in: canvas)
        guard let mapView = mapBridge.mapView else {
            draftQuad[index] = p
            return
        }
        if draftAnchoredToMap {
            draftGeoCorners[index] = mapView.convert(p, toCoordinateFrom: mapView)
            syncDraftQuadFromGeo(canvas: canvas)
        } else {
            draftQuad[index] = p
            syncDraftGeoFromScreenQuad(canvas: canvas)
        }
    }

    private func cancelDraftMapMotionSettledDebounce() {
        mapBridge.cancelDraftStickToMapSettle()
        draftMapMotionSuppressWarpUntilSettled = false
    }

    private func resetDraftMapMotionFadeState() {
        cancelDraftMapMotionSettledDebounce()
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            draftMapMotionImageOpacity = 1
        }
    }

    private static func warpedDraftCGImage(for image: UIImage, size: CGSize, quad: [CGPoint], largeRaster: Bool) -> CGImage? {
        guard size.width > 0, size.height > 0, quad.count == 4 else { return nil }
        let maxSideCap: CGFloat = largeRaster ? 2048 : 4096 // mirrors editWarpMaxSourceSideLargeRaster / editWarpMaxSourceSide
        guard let cgIn = OverlayMapBake.normalizedCGImage(from: image) else { return nil }
        let ciImage = CIImage(cgImage: cgIn)
        let extent = ciImage.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let maxSide = max(extent.width, extent.height)
        let scaleDown = min(1, maxSideCap / maxSide)
        var scaledInput = ciImage.transformed(by: CGAffineTransform(scaleX: scaleDown, y: scaleDown))
        let scaledExtent = scaledInput.extent.integral
        scaledInput = scaledInput.transformed(by: CGAffineTransform(translationX: -scaledExtent.origin.x, y: -scaledExtent.origin.y))

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = scaledInput
        filter.topLeft = uiToCoreImageStatic(point: quad[0], canvasHeight: size.height)
        filter.topRight = uiToCoreImageStatic(point: quad[1], canvasHeight: size.height)
        filter.bottomRight = uiToCoreImageStatic(point: quad[2], canvasHeight: size.height)
        filter.bottomLeft = uiToCoreImageStatic(point: quad[3], canvasHeight: size.height)

        guard let output = filter.outputImage else { return nil }
        let outScale = min(1, maxSideCap / max(size.width, size.height))
        let cropRect = CGRect(
            origin: .zero,
            size: CGSize(width: max(1, size.width * outScale), height: max(1, size.height * outScale))
        )
        let ctx = CIContext(options: [.cacheIntermediates: false])
        return ctx.createCGImage(output, from: cropRect)
    }

    private static func uiToCoreImageStatic(point: CGPoint, canvasHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: canvasHeight - point.y)
    }

    private func saveDraftAsOverlay() {
        guard let mapView = mapBridge.mapView, let draftImage, draftQuad.count == 4 else { return }

        let corners: [CLLocationCoordinate2D]
        if draftGeoCorners.count == 4 {
            corners = draftGeoCorners
        } else {
            corners = draftQuad.map { mapView.convert($0, toCoordinateFrom: mapView) }
        }
        let overlayID = editingOverlayBackup?.id ?? UUID()
        let preservedPick = draftSourceFileData
        let fallbackDisplayName = editingOverlayBackup?.displayName

        mapBridge.cancelPendingEditFit()
        finalizeDraftRasterOpacityGestureEnd()
        primaryCTAShowsActivity = true
        overlayPersistenceInFlight += 1
        OverlayLibrary.beginSaveTransition(overlayID: overlayID)

        Task {
            SnapMemoryInstrumentation.checkpoint("saveDraft.Task.begin overlayID=\(overlayID.uuidString.prefix(8))…")
            async let resolvedDisplayName = OverlayNameResolver.displayName(for: corners, fallback: fallbackDisplayName)
            let rasterBytesForBake = preservedPick
                ?? editingOverlayBackup?.sourceRasterData
                ?? OverlayLibrary.persistedSourceRasterData(overlayID: overlayID, container: persistence.container)
            let rasterBytes = rasterBytesForBake
            let intrinsicPixels: Int64 = {
                if let rasterBytes, let px = UIImage.rasterPixelCount(forCompressedImageData: rasterBytes) {
                    return px
                }
                return draftImage.rasterPixelCount()
            }()
            let bakedPreWritten = await Task.detached(priority: .userInitiated) {
                let mapDisplayImage: UIImage
                if let rasterBytesForBake,
                   let px = UIImage.rasterPixelCount(forCompressedImageData: rasterBytesForBake),
                   px > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive,
                   let subsampled = OverlayLibrary.uiImageSubsampling(from: rasterBytesForBake, maxPixelDimension: 4096) {
                    mapDisplayImage = OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: subsampled, corners: corners) ?? subsampled
                } else {
                    mapDisplayImage = OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: draftImage, corners: corners) ?? draftImage
                }
                return OverlayLibrary.persistBakedImageToDiskDuringSaveDraft(mapDisplayImage, overlayID: overlayID)
            }.value
            let displayName = await resolvedDisplayName
            SnapMemoryInstrumentation.checkpoint("saveDraft.afterBakeMercatorDetached overlayID=\(overlayID.uuidString.prefix(8))… preWritten=\(bakedPreWritten)")
            let sourceImageForModel = intrinsicPixels > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive && rasterBytes != nil
                ? OverlayItem.browseSourceMemoryPlaceholder()
                : draftImage
            await MainActor.run {
                self.warpedDraftUpdateTask?.cancel()
                self.warpedDraftCGImage = nil
                self.draftImage = nil
                draftSourceFileData = nil
                draftQuad = []
                initialDraftQuad = []
                draftAnchoredToMap = false
                draftGeoCorners = []
                initialDraftGeoCorners = []
                editingOverlayBackup = nil
                OverlayMapBake.endThumbnailCacheScope()
                OverlayMetalTilePipeline.clearSessionCache()
            }
            let placementCamera = await MainActor.run { persistMapCameraSnapshot() }
            let pendingPyramid: OverlayTilePyramidRuntimeInfo? =
                intrinsicPixels > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive
                ? OverlayTilePyramidRuntimeInfo(
                    revision: -1,
                    minimumZoom: -1,
                    maximumZoom: -1,
                    previewMaximumZoom: -1,
                    fullMaximumZoom: -1,
                    refinementInProgress: true
                )
                : nil
            await MainActor.run {
                OverlaySaveTransitionLog.stage("editResources.released", overlayID: overlayID)
                browserOpacitySliderCollapsed = true
                isEditing = false
                primaryCTAShowsActivity = false
                selectedItem = nil
                finalizeBrowsingRasterOpacityInteraction()

                var snap = overlays
                snap.append(
                    OverlayItem(
                        id: overlayID,
                        displayName: displayName,
                        sourceImage: sourceImageForModel,
                        mapDisplayImage: OverlayItem.browseSourceMemoryPlaceholder(),
                        corners: corners,
                        placementCamera: placementCamera,
                        preservedSourceFileData: preservedPick,
                        bakedImagePreWrittenToDisk: bakedPreWritten,
                        cachedSourceRasterPixels: rasterBytes.flatMap { UIImage.rasterPixelCount(forCompressedImageData: $0) },
                        sourceRasterData: rasterBytes,
                        tilePyramid: pendingPyramid
                    )
                )
                SnapMemoryInstrumentation.checkpoint(
                    "saveDraft.beforeOverlayLibrary.saveOverlays overlayCount=\(snap.count) visibleOverlays=\(overlays.count)"
                )
                OverlayLibrary.saveOverlays(
                    snap,
                    in: persistence.container,
                    forceRewriteSource: false,
                    forceRewriteBaked: false
                ) { success in
                    SnapMemoryInstrumentation.checkpoint("saveDraft.saveOverlays.completion success=\(success) id=\(overlayID.uuidString.prefix(8))…")
                    Task { @MainActor in
                        if success {
                            OverlayLibrary.setPyramidBuildSuppressed(overlayID, suppressed: false)
                            OverlayLibrary.runDeferredMinZBuildAfterSaveTransition(
                                overlayID: overlayID,
                                container: persistence.container
                            )
                            restorePersistedOverlay()
                        } else {
                            print("[Overlay] saveDraft failed id=\(overlayID.uuidString.prefix(8))…")
                        }
                        overlayPersistenceInFlight = max(0, overlayPersistenceInFlight - 1)
                    }
                }
            }
        }
    }

    private func cancelEditing() {
        mapBridge.cancelPendingEditFit()
        primaryCTAShowsActivity = false
        warpedDraftUpdateTask?.cancel()
        if let backup = editingOverlayBackup {
            OverlayLibrary.setPyramidBuildSuppressed(backup.id, suppressed: false)
        }
        draftImage = nil
        draftSourceFileData = nil
        draftQuad = []
        initialDraftQuad = []
        draftAnchoredToMap = false
        draftGeoCorners = []
        initialDraftGeoCorners = []
        if let backup = editingOverlayBackup {
            overlays.append(backup)
        }
        editingOverlayBackup = nil
        isEditing = false
        selectedItem = nil
        browserOpacitySliderCollapsed = true
        finalizeBrowsingRasterOpacityInteraction()
        persistOverlaysToStore()
    }

    private func removeEditingOverlay() {
        mapBridge.cancelPendingEditFit()
        primaryCTAShowsActivity = false
        warpedDraftUpdateTask?.cancel()
        if let backup = editingOverlayBackup {
            OverlayLibrary.setPyramidBuildSuppressed(backup.id, suppressed: false)
        }
        draftImage = nil
        draftSourceFileData = nil
        draftQuad = []
        initialDraftQuad = []
        draftAnchoredToMap = false
        draftGeoCorners = []
        initialDraftGeoCorners = []
        editingOverlayBackup = nil
        isEditing = false
        selectedItem = nil
        browserOpacitySliderCollapsed = true
        finalizeBrowsingRasterOpacityInteraction()
        persistOverlaysToStore()
    }

    private func beginEditingOverlay(id: UUID) {
        guard !isEditing, let mapView = mapBridge.mapView,
              let overlay = overlays.first(where: { $0.id == id }) else {
            return
        }

        // Drop tiled overlay + pyramid work before camera handoff so 400MP browse does not jetsam during edit entry.
        editingOverlayBackup = overlay
        OverlayLibrary.setPyramidBuildSuppressed(overlay.id, suppressed: true)
        overlays.removeAll(where: { $0.id == overlay.id })

        primaryCTAShowsActivity = overlay.usesTiledMapPresentation

        if let cam = overlay.placementCamera {
            mapBridge.armEditTransitionAfterMapSettles(for: overlay, expectedVisibleMapRect: nil)
            restoreMapCameraForEdit(cam, on: mapView)
            mapBridge.noteMapRegionChangedWhileWaitingForEdit()
        } else {
            let targetRect = mapRect(for: overlay.corners)
            let padding = UIEdgeInsets(top: 100, left: 50, bottom: 120, right: 50)
            let expectedVisibleMapRect = mapView.mapRectThatFits(targetRect, edgePadding: padding)
            mapBridge.armEditTransitionAfterMapSettles(for: overlay, expectedVisibleMapRect: expectedVisibleMapRect)
            mapView.setVisibleMapRect(targetRect, edgePadding: padding, animated: true)
            mapBridge.noteMapRegionChangedWhileWaitingForEdit()
        }
    }

    private func persistMapCameraSnapshot() -> PersistedMapCamera? {
        guard let c = mapBridge.mapView?.camera else { return nil }
        return PersistedMapCamera(
            centerLatitude: c.centerCoordinate.latitude,
            centerLongitude: c.centerCoordinate.longitude,
            heading: c.heading,
            centerCoordinateDistance: c.centerCoordinateDistance,
            pitch: Double(c.pitch)
        )
    }

    private func restoreMapCameraForEdit(_ p: PersistedMapCamera, on mapView: MKMapView) {
        let c = MKMapCamera()
        c.centerCoordinate = CLLocationCoordinate2D(latitude: p.centerLatitude, longitude: p.centerLongitude)
        c.centerCoordinateDistance = p.centerCoordinateDistance
        c.pitch = CGFloat(p.pitch)
        c.heading = p.heading
        mapView.setCamera(c, animated: true)
    }

    private func applyMapEditTransition(_ handoff: MapEditHandoff, canvas: CGSize) {
        let overlay = handoff.overlay
        guard !isEditing else {
            primaryCTAShowsActivity = false
            return
        }

        draftSourceFileData = overlay.preservedSourceFileData
            ?? overlay.sourceRasterData
            ?? OverlayLibrary.persistedSourceRasterData(overlayID: overlay.id, container: persistence.container)
        draftSourceExceedsLargeOverlayThreshold = overlay.usesTiledMapPresentation
        draftAnchoredToMap = true
        draftGeoCorners = overlay.corners
        initialDraftGeoCorners = overlay.corners
        resetDraftMapMotionFadeState()
        draftQuad = handoff.fittedQuadScreen
        initialDraftQuad = handoff.fittedQuadScreen
        draftOverlayOpacityCommitted = 0.5
        draftOverlayOpacityDragging = nil
        browserOpacitySliderCollapsed = false
        finalizeBrowsingRasterOpacityInteraction()
        if editingOverlayBackup?.id != overlay.id {
            editingOverlayBackup = overlay
            overlays.removeAll(where: { $0.id == overlay.id })
        }
        OverlayLibrary.setPyramidBuildSuppressed(overlay.id, suppressed: true)
        isEditing = true

        Task {
            let previewMax: CGFloat = overlay.usesTiledMapPresentation ? 2048 : 4096
            let preview = await Task.detached(priority: .userInitiated) {
                overlay.editingPreviewUIImage(maxPixelDimension: previewMax)
            }.value
            await MainActor.run {
                draftImage = preview ?? overlay.sourceImage
                updateWarpedDraftCache(canvas: canvas)
                primaryCTAShowsActivity = false
            }
        }
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

    private func persistOverlaysToStore(forceRewriteSource: Bool = false, forceRewriteBaked: Bool = false) {
        let snapshot = overlays
        overlayPersistenceInFlight += 1
        OverlayLibrary.saveOverlays(
            snapshot,
            in: persistence.container,
            forceRewriteSource: forceRewriteSource,
            forceRewriteBaked: forceRewriteBaked
        ) { success in
            Task { @MainActor in
                if success {
                    restorePersistedOverlay()
                }
                overlayPersistenceInFlight = max(0, overlayPersistenceInFlight - 1)
            }
        }
    }

    private func loadOverlaysFromStoreSync() {
        isEditing = false
        let viewContext = persistence.container.viewContext
        viewContext.processPendingChanges()
        do {
            overlays = try OverlayLibrary.loadOverlays(viewContext: viewContext)
        } catch {
            print("[Overlay] loadOverlays failed: \(error)")
            overlays = []
        }
    }

    private func restorePersistedOverlay() {
        restorePersistedOverlayToken &+= 1
        let token = restorePersistedOverlayToken
        Task { @MainActor in
            await Task.yield()
            guard token == restorePersistedOverlayToken else { return }
            loadOverlaysFromStoreSync()
        }
    }

    private func collapseBrowsingOpacitySliderIfNeeded() {
        guard !isEditing, !browserOpacitySliderCollapsed else { return }
        finalizeBrowsingRasterOpacityInteraction()
        browserOpacitySliderCollapsed = true
    }

    private func finalizeBrowsingRasterOpacityInteraction(_ finalAlpha: Double? = nil) {
        let bridgeDragging = mapBridge.rasterOpacity.dragging.map { Double($0) }
        let merged = min(max(finalAlpha ?? bridgeDragging ?? mapRasterOpacityDragging ?? mapRasterOpacityCommitted, 0), 1)
        mapRasterOpacityCommitted = merged
        mapRasterOpacityDragging = nil
        mapBridge.rasterOpacity.committed = CGFloat(merged)
        mapBridge.rasterOpacity.clearDragging()
        mapBridge.applyRasterOverlayRendererAlphas()
    }

    private func browsingRasterOpacitySyncBagAndRedraw(liveDragging: Double? = nil, duringLiveDragOnChanged: Bool = false) {
        guard !isEditing else { return }
        let allDisplayedRastersAreLarge = mapBridge.displayedMapRastersAreAllLargeImage
        if duringLiveDragOnChanged, allDisplayedRastersAreLarge {
            return
        }

        mapBridge.rasterOpacity.committed = CGFloat(min(max(mapRasterOpacityCommitted, 0), 1))
        if let liveDragging {
            mapBridge.rasterOpacity.dragging = allDisplayedRastersAreLarge
                ? nil
                : CGFloat(min(max(liveDragging, 0), 1))
        } else if let dragging = mapRasterOpacityDragging {
            mapBridge.rasterOpacity.dragging = allDisplayedRastersAreLarge
                ? nil
                : CGFloat(min(max(dragging, 0), 1))
        } else {
            mapBridge.rasterOpacity.dragging = nil
        }

        mapBridge.applyRasterOverlayRendererAlphas()
    }
}

private struct BrowseAddControl: View {
    enum Presentation: Equatable {
        case labeled
        case iconOnly
    }

    let presentation: Presentation
    let maxLabelWidth: CGFloat
    let bottomInset: CGFloat
    @Binding var selectedItem: PhotosPickerItem?
    var namespace: Namespace.ID
    var onInteraction: () -> Void

    private var dimension: CGFloat { MapControlChrome.bottomBaseDimension }

    var body: some View {
        PhotosPicker(selection: $selectedItem, matching: .images) {
            pickerLabel
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { onInteraction() })
        .padding(.bottom, bottomInset)
    }

    @ViewBuilder
    private var pickerLabel: some View {
        switch presentation {
        case .labeled:
            MapControlChrome.glassCapsuleFrame(
                width: min(maxLabelWidth, 220),
                height: dimension
            ) {
                HStack(spacing: 10) {
                    Text("Add image")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(MapControlChrome.accentColor)
                    browseAddIcon
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .matchedGeometryEffect(id: "browseAddChrome", in: namespace)
        case .iconOnly:
            MapControlChrome.circularControl(.standard, diameter: dimension) {
                browseAddIcon
            }
            .matchedGeometryEffect(id: "browseAddChrome", in: namespace)
        }
    }

    private var browseAddIcon: some View {
        Image(systemName: "photo.badge.plus")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(MapControlChrome.accentColor)
            .matchedGeometryEffect(id: "browseAddIcon", in: namespace)
    }
}

