import SwiftUI
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
    @State private var warpedDraftCGImage: CGImage?
    @State private var primaryCTAShowsActivity: Bool = false
    /// Bytes from **`PhotosPicker`** (`Data.self`); copied into Core Data on first save without recompression.
    @State private var draftSourceFileData: Data?
    /// True when the **picked / persisted** raster exceeds **`OverlayLibrary.largeRasterOverlayPixelThresholdExclusive`** ( **`draftImage`** may be subsampled).
    @State private var draftSourceExceedsLargeOverlayThreshold = false
    /// Nested saves bump this (e.g. rapid actions); indicator stays until all complete.
    @State private var overlayPersistenceInFlight: Int = 0
    /// Debug-only current pyramid iteration z while background build is running.
    @State private var debugPyramidIterationZoomLevel: Int?
    /// Debug-only in-level progress x/L for current pyramid zoom level.
    @State private var debugPyramidIterationTileIndex: Int?
    @State private var debugPyramidIterationTileTotal: Int?
    /// Debug-only elapsed seconds in current pyramid level.
    @State private var debugPyramidIterationElapsedSeconds: Double?
    /// Debug-only phase label (`preview` / `refine` / `full`) for pyramid progress.
    @State private var debugPyramidIterationPhase: String?
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
                    isEditing: isEditing,
                    browsingOpacitySliderExpanded: !browserOpacitySliderCollapsed && !isEditing,
                    onRequestDismissBrowsingOpacitySlider: collapseBrowsingOpacitySliderIfNeeded,
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
            .overlay(alignment: .bottomLeading) {
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
                    .padding(.leading, 16)
                    .padding(.bottom, geometry.safeAreaInsets.bottom + 8)
                }
            }
            /// **`bottomLeading`** (opacity) is applied **before** this overlay so the trailing edit column stays **above** it in hit‑testing / drawing order.
            .overlay(alignment: .bottomTrailing) {
                bottomTrailingChrome(canvas: geometry.size, bottomInset: geometry.safeAreaInsets.bottom)
                    .zIndex(10)
            }
            .animation(.easeInOut(duration: 0.2), value: isEditing)
            .animation(.easeInOut(duration: 0.2), value: mapBridge.isAnyRasterMapOverlayOnMap)
            .onChange(of: mapBridge.isAnyRasterMapOverlayOnMap) { _, hasRaster in
                if !hasRaster, !isEditing {
                    collapseBrowsingOpacitySliderIfNeeded()
                }
            }
            .onChange(of: overlayPersistenceInFlight) { _, inFlight in
                if inFlight <= 0, !hasRefiningPyramids {
                    debugPyramidIterationZoomLevel = nil
                    debugPyramidIterationTileIndex = nil
                    debugPyramidIterationTileTotal = nil
                    debugPyramidIterationElapsedSeconds = nil
                    debugPyramidIterationPhase = nil
                }
            }
            .onAppear {
                mapBridge.requestLocationAuthorizationIfNeeded()
                mapBridge.rasterOpacity.committed = CGFloat(min(max(mapRasterOpacityCommitted, 0), 1))
                mapBridge.rasterOpacity.clearDragging()
                mapBridge.applyRasterOverlayRendererAlphas()
                if !hasAttemptedRestore {
                    hasAttemptedRestore = true
                    OverlayLibrary.resumePendingRefinements(in: persistence.container) {
                        OverlayLibrary.resumeUnderestimatedPyramidCeilings(in: persistence.container) {
                            restorePersistedOverlay()
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayTilePyramidIterationDidChange)) { note in
                let finished = (note.userInfo?[OverlayTilePyramidBuilder.debugIterationFinishedKey] as? Bool) ?? false
                if finished {
                    if !hasRefiningPyramids && overlayPersistenceInFlight <= 0 {
                        debugPyramidIterationZoomLevel = nil
                        debugPyramidIterationTileIndex = nil
                        debugPyramidIterationTileTotal = nil
                        debugPyramidIterationElapsedSeconds = nil
                        debugPyramidIterationPhase = nil
                    }
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
                if let phase = note.userInfo?[OverlayTilePyramidBuilder.debugIterationPhaseKey] as? String {
                    debugPyramidIterationPhase = phase
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .overlayTilePyramidRefinementDidComplete)) { _ in
                restorePersistedOverlay()
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
        }
    }

    /// Center: `.primaryCTA` for Add / Done; uses `MapControlChrome.Appearance.primaryCTA`.
    private func bottomCenterControl(bottomInset: CGFloat) -> some View {
        let d = MapControlChrome.diameter
        let tap = d + 2
        return ZStack(alignment: .bottom) {
            Circle()
                .fill(Color.clear)
                .frame(width: tap, height: tap)
                .contentShape(Circle())
            Group {
                if isEditing {
                    if primaryCTAShowsActivity {
                        MapControlChrome.circularControl(.primaryCTA) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }
                    } else {
                        MapControlChrome.primaryCTAButton(icon: "checkmark", fontSize: 20) {
                            collapseBrowsingOpacitySliderIfNeeded()
                            saveDraftAsOverlay()
                        }
                    }
                } else {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        MapControlChrome.circularControl(.primaryCTA) {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .regular))
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { collapseBrowsingOpacitySliderIfNeeded() })
                }
            }
        }
        .frame(width: tap, height: tap, alignment: .bottom)
        .padding(.bottom, bottomInset + 8)
    }

    /// Bottom-trailing: persistence spinner, then reset-distort above cancel when editing.
    @ViewBuilder
    private func bottomTrailingChrome(canvas: CGSize, bottomInset: CGFloat) -> some View {
        if overlayPersistenceInFlight > 0 || hasRefiningPyramids || isEditing {
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
            .padding(.trailing, 16)
            .padding(.bottom, bottomInset + 8)
        }
    }

    private var overlayPersistenceSavingIndicator: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let z = debugPyramidIterationZoomLevel {
                let progressLabel: String = {
                    let phasePrefix: String = {
                        switch debugPyramidIterationPhase {
                        case OverlayTilePyramidBuilder.BuildPhase.preview.rawValue:
                            return "Preview"
                        case OverlayTilePyramidBuilder.BuildPhase.refine.rawValue:
                            return "Refine"
                        case OverlayTilePyramidBuilder.BuildPhase.full.rawValue:
                            return "Build"
                        default:
                            return "PyrDown"
                        }
                    }()
                    let elapsedSuffix: String = {
                        guard let elapsed = debugPyramidIterationElapsedSeconds else { return "" }
                        return String(format: " %.1fs", elapsed)
                    }()
                    if let x = debugPyramidIterationTileIndex, let total = debugPyramidIterationTileTotal, total > 0 {
                        return "\(phasePrefix) z\(z)\n\(x)/\(total)\(elapsedSuffix)"
                    }
                    return "\(phasePrefix) z\(z)\n\(elapsedSuffix)"
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
        var ciImage = CIImage(cgImage: cgIn)
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

        mapBridge.cancelPendingEditFit()
        finalizeDraftRasterOpacityGestureEnd()
        primaryCTAShowsActivity = true
        overlayPersistenceInFlight += 1

        Task {
            SnapMemoryInstrumentation.checkpoint("saveDraft.Task.begin overlayID=\(overlayID.uuidString.prefix(8))…")
            let rasterBytesForBake = preservedPick ?? editingOverlayBackup?.sourceRasterData
            let mapDisplayImage = await Task.detached(priority: .userInitiated) {
                if let rasterBytesForBake,
                   let px = UIImage.rasterPixelCount(forCompressedImageData: rasterBytesForBake),
                   px > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive,
                   let subsampled = OverlayLibrary.uiImageSubsampling(from: rasterBytesForBake, maxPixelDimension: 4096) {
                    return OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: subsampled, corners: corners) ?? subsampled
                }
                return OverlayMapBake.bakeMercatorDisplayTextureForBrowse(source: draftImage, corners: corners) ?? draftImage
            }.value
            SnapMemoryInstrumentation.checkpoint("saveDraft.afterBakeMercatorDetached overlayID=\(overlayID.uuidString.prefix(8))…")
            let placementCamera = await MainActor.run { persistMapCameraSnapshot() }
            let rasterBytes = preservedPick ?? editingOverlayBackup?.sourceRasterData
            let intrinsicPixels: Int64 = {
                if let rasterBytes, let px = UIImage.rasterPixelCount(forCompressedImageData: rasterBytes) {
                    return px
                }
                return draftImage.rasterPixelCount()
            }()
            let sourceImageForModel = intrinsicPixels > OverlayLibrary.largeRasterOverlayPixelThresholdExclusive && rasterBytes != nil
                ? OverlayItem.browseSourceMemoryPlaceholder()
                : draftImage
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
                overlays.append(
                    OverlayItem(
                        id: overlayID,
                        sourceImage: sourceImageForModel,
                        mapDisplayImage: mapDisplayImage,
                        corners: corners,
                        placementCamera: placementCamera,
                        preservedSourceFileData: preservedPick,
                        sourceRasterData: rasterBytes,
                        tilePyramid: pendingPyramid
                    )
                )
                SnapMemoryInstrumentation.checkpoint(
                    "saveDraft.overlayAppendedMainActor id=\(overlayID.uuidString.prefix(8))… tiled=\(overlays.last?.usesTiledMapPresentation ?? false) overlays.count=\(overlays.count)"
                )

                self.warpedDraftUpdateTask?.cancel()
                OverlayLibrary.setPyramidBuildSuppressed(overlayID, suppressed: false)
                self.draftImage = nil
                draftSourceFileData = nil
                draftQuad = []
                initialDraftQuad = []
                draftAnchoredToMap = false
                draftGeoCorners = []
                initialDraftGeoCorners = []
                editingOverlayBackup = nil

                browserOpacitySliderCollapsed = true
                isEditing = false
                primaryCTAShowsActivity = false
                selectedItem = nil
                finalizeBrowsingRasterOpacityInteraction()

                let snap = overlays
                SnapMemoryInstrumentation.checkpoint("saveDraft.beforeOverlayLibrary.saveOverlays overlayCount=\(snap.count)")
                OverlayLibrary.saveOverlays(
                    snap,
                    in: persistence.container,
                    forceRewriteSource: false,
                    forceRewriteBaked: false
                ) { success in
                    SnapMemoryInstrumentation.checkpoint("saveDraft.saveOverlays.completion success=\(success) id=\(overlayID.uuidString.prefix(8))…")
                    Task { @MainActor in
                        if let idx = overlays.firstIndex(where: { $0.id == overlayID }) {
                            overlays[idx].preservedSourceFileData = nil
                        }
                        if success {
                            restorePersistedOverlay()
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

        draftSourceFileData = overlay.preservedSourceFileData ?? overlay.sourceRasterData
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

    private func restorePersistedOverlay() {
        isEditing = false
        do {
            overlays = try OverlayLibrary.loadOverlays(viewContext: persistence.container.viewContext)
        } catch {
            overlays = []
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
