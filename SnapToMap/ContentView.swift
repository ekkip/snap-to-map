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
                }
            }
            .onChange(of: draftWarpCacheSignature(canvas: geometry.size)) { _, _ in
                guard isEditing else { return }
                updateWarpedDraftCache(canvas: geometry.size)
            }
            .overlay(alignment: .topLeading) {
                if isEditing, editingOverlayBackup != nil {
                    chromeIconButton(icon: "trash", fontSize: 20) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        removeEditingOverlay()
                    }
                    .padding(.leading, 16)
                    .padding(.top, geometry.safeAreaInsets.top + 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 12) {
                    MapCompassRepresentable(bridge: mapBridge)
                        .fixedSize()
                    chromeIconButton(icon: "location.fill", fontSize: 22) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        mapBridge.centerOnUserLocation()
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { collapseBrowsingOpacitySliderIfNeeded() })
                .padding(.top, geometry.safeAreaInsets.top + 8)
                .padding(.trailing, 16)
            }
            .overlay(alignment: .bottom) {
                bottomCenterControl(canvas: geometry.size, bottomInset: geometry.safeAreaInsets.bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                bottomTrailingEditHUD(canvas: geometry.size, bottomInset: geometry.safeAreaInsets.bottom)
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
            .onChange(of: mapBridge.mapEditHandoff?.overlay.id) { _, _ in
                guard let handoff = mapBridge.mapEditHandoff else { return }
                mapBridge.mapEditHandoff = nil
                applyMapEditTransition(handoff, canvas: geometry.size)
            }
        }
    }

    /// Center: `.primaryCTA` for Add / Done; uses `MapControlChrome.Appearance.primaryCTA`.
    private func bottomCenterControl(canvas: CGSize, bottomInset: CGFloat) -> some View {
        HStack {
            Spacer(minLength: 0)
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
            Spacer(minLength: 0)
        }
        .padding(.bottom, bottomInset + 8)
    }

    /// Bottom-trailing: reset-distort above cancel. User-location stays under compass.
    @ViewBuilder
    private func bottomTrailingEditHUD(canvas: CGSize, bottomInset: CGFloat) -> some View {
        if isEditing {
            VStack(alignment: .trailing, spacing: 12) {
                if hasCornerEdits {
                    chromeIconButton(icon: "arrow.counterclockwise", fontSize: 20) {
                        collapseBrowsingOpacitySliderIfNeeded()
                        resetDraftQuad(for: canvas)
                    }
                }
                chromeIconButton(icon: "xmark", fontSize: 20) {
                    collapseBrowsingOpacitySliderIfNeeded()
                    cancelEditing()
                }
            }
            .simultaneousGesture(TapGesture().onEnded { collapseBrowsingOpacitySliderIfNeeded() })
            .padding(.trailing, 16)
            .padding(.bottom, bottomInset + 8)
        }
    }

    private func chromeIconButton(icon: String, fontSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MapControlChrome.circularControl(.standard) {
                Image(systemName: icon)
                    .font(.system(size: fontSize, weight: .regular))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func draftOverlay(canvas: CGSize, warped: CGImage) -> some View {
        Image(decorative: warped, scale: 1, orientation: .up)
            .resizable()
            .frame(width: canvas.width, height: canvas.height)
            .opacity(draftWarpDisplayOpacity)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    private func draftWarpCacheSignature(canvas: CGSize) -> String {
        guard let img = draftImage else { return "_" }
        let oid = ObjectIdentifier(img as AnyObject)
        let q = draftQuad.map { String(format: "%.2f,%.2f", $0.x, $0.y) }.joined(separator: "|")
        return "\(oid)|\(Int(canvas.width))x\(Int(canvas.height))|\(q)"
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
                                draftQuad[index] = clamp(value.location, in: canvas)
                            }
                    )
            }
        }
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
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), size.width),
            y: min(max(point.y, 0), size.height)
        )
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

        let corners = draftQuad.map { mapView.convert($0, toCoordinateFrom: mapView) }
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

        overlays.append(OverlayItem(id: overlayID, sourceImage: draftImage, corners: corners))

        self.draftImage = nil
        draftQuad = []
        initialDraftQuad = []
        editingOverlayBackup = nil

        browserOpacitySliderCollapsed = true
        isEditing = false
        selectedItem = nil
        finalizeBrowsingRasterOpacityInteraction()
        persistOverlaysSkippingUnchangedImages()
        primaryCTAShowsActivity = false
    }

    private func cancelEditing() {
        mapBridge.cancelPendingEditFit()
        primaryCTAShowsActivity = false
        draftImage = nil
        draftQuad = []
        initialDraftQuad = []
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

        let targetRect = mapRect(for: overlay.corners)
        let padding = UIEdgeInsets(top: 100, left: 50, bottom: 120, right: 50)
        let expectedVisibleMapRect = mapView.mapRectThatFits(targetRect, edgePadding: padding)

        primaryCTAShowsActivity = overlay.sourceImage.rasterExceedsLargeOverlayPixelThreshold

        mapBridge.armEditTransitionAfterMapSettles(for: overlay, expectedVisibleMapRect: expectedVisibleMapRect)

        mapView.setVisibleMapRect(targetRect, edgePadding: padding, animated: true)
        mapBridge.noteMapRegionChangedWhileWaitingForEdit()
    }

    private func applyMapEditTransition(_ handoff: MapEditHandoff, canvas: CGSize) {
        let overlay = handoff.overlay
        guard !isEditing, overlays.contains(where: { $0.id == overlay.id }) else {
            primaryCTAShowsActivity = false
            return
        }

        draftImage = overlay.sourceImage
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

    /// Writes **`saved-overlays.json`** always; raster files only when missing or **`forceRewriteAllImages`**.
    /// Cancel / Delete therefore avoid **`jpegData`/`pngData`** on unchanged on-disk overlays.
    private func persistOverlaysSkippingUnchangedImages(forceRewriteAllImages: Bool = false) {
        struct PersistRow: Sendable {
            let id: UUID
            let imageBytes: Data?
            let corners: [PersistedCoordinate]
            let imageFileURL: URL
        }

        let directoryURL = overlaysDirectoryURL()
        let metadataURL = overlaysMetadataURL()

        var rows: [PersistRow] = []
        rows.reserveCapacity(overlays.count)
        var activeRelativeNames = Set<String>()

        let fm = FileManager.default
        for o in overlays {
            let imageURL = directoryURL.appendingPathComponent(Self.overlayImageFilename(id: o.id))
            activeRelativeNames.insert(imageURL.lastPathComponent)

            let needsImageWrite = forceRewriteAllImages || !fm.fileExists(atPath: imageURL.path)
            let encoded: Data? = needsImageWrite
                ? (o.sourceImage.jpegData(compressionQuality: 0.92) ?? o.sourceImage.pngData())
                : nil

            rows.append(PersistRow(
                id: o.id,
                imageBytes: encoded,
                corners: o.corners.map { PersistedCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                imageFileURL: imageURL
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
                    entries.append(PersistedOverlayEntry(id: row.id, corners: row.corners))
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
            restored.append(
                OverlayItem(
                    id: entry.id,
                    sourceImage: sourceImage,
                    corners: corners
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
