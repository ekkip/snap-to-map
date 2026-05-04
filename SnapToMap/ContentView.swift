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
    @StateObject private var mapBridge = MapViewBridge()
    private let ciContext = CIContext()

    private let overlaysMetadataFilename = "saved-overlays.json"
    private let overlaysDirectoryName = "overlay-images"
    private let distortHandleDiameter: CGFloat = 31
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
                bottomTrailingEditHUD(canvas: geometry.size, bottomInset: geometry.safeAreaInsets.bottom)
                    .zIndex(10)
            }
            .animation(.easeInOut(duration: 0.2), value: isEditing)
            .animation(.easeInOut(duration: 0.2), value: mapBridge.isAnyRasterMapOverlayOnMap)
            .onChange(of: mapBridge.isAnyRasterMapOverlayOnMap) { _, hasRaster in
                if !hasRaster, !isEditing {
                    collapseBrowsingOpacitySliderIfNeeded()
                }
            }
            .onAppear {
                mapBridge.requestLocationAuthorizationIfNeeded()
                mapBridge.rasterOpacity.committed = CGFloat(min(max(mapRasterOpacityCommitted, 0), 1))
                mapBridge.rasterOpacity.clearDragging()
                mapBridge.applyRasterOverlayRendererAlphas()
                if !hasAttemptedRestore {
                    hasAttemptedRestore = true
                    restorePersistedOverlay()
                }
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
                } else if primaryCTAShowsActivity {
                    MapControlChrome.circularControl(.primaryCTA) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
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

    /// Bottom-trailing: reset-distort above cancel. User-location stays under compass.
    @ViewBuilder
    private func bottomTrailingEditHUD(canvas: CGSize, bottomInset: CGFloat) -> some View {
        if isEditing {
            VStack(alignment: .trailing, spacing: 8) {
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
            .simultaneousGesture(TapGesture().onEnded { collapseBrowsingOpacitySliderIfNeeded() })
            .padding(.trailing, 16)
            .padding(.bottom, bottomInset + 8)
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
        guard isEditing, let image = draftImage, draftQuad.count == 4, canvas.width > 1, canvas.height > 1 else {
            warpedDraftCGImage = nil
            return
        }
        warpedDraftCGImage = warpedImageCG(for: image, size: canvas, quad: draftQuad)
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
        let v = draftImage.rasterExceedsLargeOverlayPixelThreshold
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
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                await MainActor.run { primaryCTAShowsActivity = false }
                return
            }

            await MainActor.run {
                mapBridge.cancelPendingEditFit()
                draftImage = image
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

    private func warpedImageCG(for image: UIImage, size: CGSize, quad: [CGPoint]) -> CGImage? {
        guard size.width > 0, size.height > 0, quad.count == 4, let ciImage = CIImage(image: image) else {
            return nil
        }

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = ciImage
        filter.topLeft = uiToCoreImage(point: quad[0], canvasHeight: size.height)
        filter.topRight = uiToCoreImage(point: quad[1], canvasHeight: size.height)
        filter.bottomRight = uiToCoreImage(point: quad[2], canvasHeight: size.height)
        filter.bottomLeft = uiToCoreImage(point: quad[3], canvasHeight: size.height)

        guard let output = filter.outputImage else { return nil }
        let cropRect = CGRect(origin: .zero, size: size)
        return ciContext.createCGImage(output, from: cropRect)
    }

    private func uiToCoreImage(point: CGPoint, canvasHeight: CGFloat) -> CGPoint {
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

        if draftImage.rasterExceedsLargeOverlayPixelThreshold {
            primaryCTAShowsActivity = true
            Task { @MainActor in
                await Task.yield()
                await Task.yield()
                finishSaveDraftAsOverlay(draftImage: draftImage, corners: corners, overlayID: overlayID)
            }
        } else {
            finishSaveDraftAsOverlay(draftImage: draftImage, corners: corners, overlayID: overlayID)
        }
    }

    private func finishSaveDraftAsOverlay(draftImage: UIImage, corners: [CLLocationCoordinate2D], overlayID: UUID) {
        mapBridge.cancelPendingEditFit()
        finalizeDraftRasterOpacityGestureEnd()

        let mapDisplayImage = OverlayMapBake.bakeMercatorDisplayTexture(source: draftImage, corners: corners) ?? draftImage
        overlays.append(
            OverlayItem(
                id: overlayID,
                sourceImage: draftImage,
                mapDisplayImage: mapDisplayImage,
                corners: corners,
                placementCamera: persistMapCameraSnapshot()
            )
        )

        self.draftImage = nil
        draftQuad = []
        initialDraftQuad = []
        draftAnchoredToMap = false
        draftGeoCorners = []
        initialDraftGeoCorners = []
        editingOverlayBackup = nil

        browserOpacitySliderCollapsed = true
        isEditing = false
        selectedItem = nil
        finalizeBrowsingRasterOpacityInteraction()
        persistOverlaysSkippingUnchangedImages(forceRewriteBaked: true)
        primaryCTAShowsActivity = false
    }

    private func cancelEditing() {
        mapBridge.cancelPendingEditFit()
        primaryCTAShowsActivity = false
        draftImage = nil
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
        persistOverlaysSkippingUnchangedImages()
    }

    private func removeEditingOverlay() {
        mapBridge.cancelPendingEditFit()
        primaryCTAShowsActivity = false
        draftImage = nil
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
        persistOverlaysSkippingUnchangedImages()
    }

    private func beginEditingOverlay(id: UUID) {
        guard !isEditing, let mapView = mapBridge.mapView,
              let overlay = overlays.first(where: { $0.id == id }) else {
            return
        }

        primaryCTAShowsActivity = overlay.sourceImage.rasterExceedsLargeOverlayPixelThreshold

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
        guard !isEditing, overlays.contains(where: { $0.id == overlay.id }) else {
            primaryCTAShowsActivity = false
            return
        }

        draftImage = overlay.sourceImage
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
        overlays.removeAll(where: { $0.id == overlay.id })
        editingOverlayBackup = overlay
        isEditing = true
        updateWarpedDraftCache(canvas: canvas)
        primaryCTAShowsActivity = false
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

    /// Writes **`saved-overlays.json`** always; source rasters when missing or **`forceRewriteAllImages`**;
    /// baked Mercator browse textures when missing, when **`forceRewriteBaked`** (e.g. after save), or with **`forceRewriteAllImages`**.
    /// Cancel / Delete therefore avoid **`jpegData`/`pngData`** on unchanged on-disk overlays.
    private func persistOverlaysSkippingUnchangedImages(forceRewriteAllImages: Bool = false, forceRewriteBaked: Bool = false) {
        struct PersistRow: Sendable {
            let id: UUID
            let imageBytes: Data?
            let bakedBytes: Data?
            let corners: [PersistedCoordinate]
            let placementCamera: PersistedMapCamera?
            let imageFileURL: URL
            let bakedFileURL: URL
        }

        let directoryURL = overlaysDirectoryURL()
        let metadataURL = overlaysMetadataURL()

        var rows: [PersistRow] = []
        rows.reserveCapacity(overlays.count)
        var activeRelativeNames = Set<String>()

        let fm = FileManager.default
        for o in overlays {
            let imageURL = directoryURL.appendingPathComponent(Self.overlayImageFilename(id: o.id))
            let bakedURL = directoryURL.appendingPathComponent(Self.overlayBakedImageFilename(id: o.id))
            activeRelativeNames.insert(imageURL.lastPathComponent)
            activeRelativeNames.insert(bakedURL.lastPathComponent)

            let needsImageWrite = forceRewriteAllImages || !fm.fileExists(atPath: imageURL.path)
            let needsBakedWrite =
                forceRewriteBaked || forceRewriteAllImages || !fm.fileExists(atPath: bakedURL.path)
            let encoded: Data? = needsImageWrite
                ? (o.sourceImage.jpegData(compressionQuality: 0.92) ?? o.sourceImage.pngData())
                : nil
            let bakedEncoded: Data? = needsBakedWrite
                ? (o.mapDisplayImage.pngData() ?? o.mapDisplayImage.jpegData(compressionQuality: 0.92))
                : nil

            rows.append(PersistRow(
                id: o.id,
                imageBytes: encoded,
                bakedBytes: bakedEncoded,
                corners: o.corners.map { PersistedCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                placementCamera: o.placementCamera,
                imageFileURL: imageURL,
                bakedFileURL: bakedURL
            ))
        }

        Task.detached(priority: .utility) {
            do {
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                let currentFiles = (try? fm.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil
                )) ?? []
                for fileURL in currentFiles where !activeRelativeNames.contains(fileURL.lastPathComponent) {
                    try? fm.removeItem(at: fileURL)
                }

                var entries: [PersistedOverlayEntry] = []
                entries.reserveCapacity(rows.count)

                for row in rows {
                    if let bytes = row.imageBytes {
                        try bytes.write(to: row.imageFileURL, options: [.atomic])
                    }
                    if let baked = row.bakedBytes {
                        try baked.write(to: row.bakedFileURL, options: [.atomic])
                        let legacyJpg = row.bakedFileURL.deletingLastPathComponent()
                            .appendingPathComponent("\(row.id.uuidString)-baked.jpg")
                        try? fm.removeItem(at: legacyJpg)
                    }
                    entries.append(PersistedOverlayEntry(
                        id: row.id,
                        corners: row.corners,
                        placementCamera: row.placementCamera
                    ))
                }

                let metadataData = try JSONEncoder().encode(PersistedOverlays(entries: entries))
                try metadataData.write(to: metadataURL, options: [.atomic])
            } catch {
                // Keep this intentionally silent for the simple demo app.
            }
        }
    }



    private static func overlayImageFilename(id: UUID) -> String {
        "\(id.uuidString).png"
    }

    private static func overlayBakedImageFilename(id: UUID) -> String {
        "\(id.uuidString)-baked.png"
    }

    private static func overlayLegacyBakedJpegFilename(id: UUID) -> String {
        "\(id.uuidString)-baked.jpg"
    }

    private func restorePersistedOverlay() {
        isEditing = false

        guard let metadataData = try? Data(contentsOf: overlaysMetadataURL()) else {
            overlays = []
            return
        }

        let persisted: PersistedOverlays
        do {
            persisted = try JSONDecoder().decode(PersistedOverlays.self, from: metadataData)
        } catch {
            overlays = []
            return
        }

        let directoryURL = overlaysDirectoryURL()

        var restored: [OverlayItem] = []
        restored.reserveCapacity(persisted.entries.count)

        for entry in persisted.entries {
            guard entry.corners.count == 4 else {
                overlays = []
                return
            }

            let imageURL = directoryURL.appendingPathComponent(Self.overlayImageFilename(id: entry.id))
            guard let imageData = try? Data(contentsOf: imageURL),
                  let sourceImage = UIImage(data: imageData) else {
                overlays = []
                return
            }

            let corners = entry.corners.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let bakedPNGURL = directoryURL.appendingPathComponent(Self.overlayBakedImageFilename(id: entry.id))
            let bakedLegacyJPGURL = directoryURL.appendingPathComponent(Self.overlayLegacyBakedJpegFilename(id: entry.id))
            let mapDisplayImage: UIImage
            if let url = [bakedPNGURL, bakedLegacyJPGURL].first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               let bakedData = try? Data(contentsOf: url),
               let baked = UIImage(data: bakedData) {
                mapDisplayImage = baked
            } else {
                mapDisplayImage =
                    OverlayMapBake.bakeMercatorDisplayTexture(source: sourceImage, corners: corners) ?? sourceImage
            }
            restored.append(
                OverlayItem(
                    id: entry.id,
                    sourceImage: sourceImage,
                    mapDisplayImage: mapDisplayImage,
                    corners: corners,
                    placementCamera: entry.placementCamera
                )
            )
        }

        overlays = restored
    }

    private func overlaysMetadataURL() -> URL {
        documentsDirectory().appendingPathComponent(overlaysMetadataFilename)
    }

    private func overlaysDirectoryURL() -> URL {
        documentsDirectory().appendingPathComponent(overlaysDirectoryName, isDirectory: true)
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

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
