import SwiftUI
import UIKit

/// Decorative treatment for circular map-adjacent controls: **standard** (Liquid Glass → material fallback) vs **primary CTA** (blue).
enum MapControlChrome {
    static let diameter: CGFloat = 46

    enum Appearance: Equatable {
        /// Liquid Glass on iOS 26+; `ultraThinMaterial` + subtle ring on earlier OS. Uses system glyph colouring.
        case standard
        /// Solid blue circle with a white glyph — use only for primary actions (add, done).
        case primaryCTA
    }

    @ViewBuilder
    static func circularControl<Content: View>(
        _ appearance: Appearance,
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch appearance {
        case .standard:
            standardChrome(content: content)
        case .primaryCTA:
            primaryCTAChrome(content: content)
        }
    }

    /// Full `Button` with **primary CTA** chrome (e.g. Done).
    static func primaryCTAButton(icon: String = "checkmark", fontSize: CGFloat = 20, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circularControl(.primaryCTA) {
                Image(systemName: icon)
                    .font(.system(size: fontSize, weight: .regular))
            }
        }
        .buttonStyle(.plain)
    }

    /// Vertical pill track (e.g. opacity slider): Liquid Glass on iOS 26+, material fallback earlier.
    @ViewBuilder
    static func glassCapsuleFrame<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content()
                    .frame(width: width, height: height)
                    .clipShape(Capsule())
                    .glassEffect(.regular, in: Capsule())
            } else {
                content()
                    .frame(width: width, height: height)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Private builders

    @ViewBuilder
    private static func standardChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content()
                    .frame(width: diameter, height: diameter)
                    .glassEffect(.regular, in: Circle())
            } else {
                content()
                    .frame(width: diameter, height: diameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private static func primaryCTAChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Color.blue, in: Circle())
    }
}

/// Opacity control for draft (SwiftUI warp) vs map raster bag. Map tile opacity during a browse drag is gated by **`MapViewBridge.displayedMapRastersAreAllLargeImage`** inside **`browsingRasterOpacitySyncBagAndRedraw`** (not by edit vs browse).
struct OverlayOpacitySlider: View {
    let isEditing: Bool
    @Binding var browserCollapsed: Bool

    @Binding var draftOpacityCommitted: Double
    @Binding var draftOpacityDragging: Double?

    /// Performed on **`DragGesture.onEnded`** for the draft raster track (commits **`draftOpacityDragging`** → **`draftOpacityCommitted`**).
    var finalizeDraftDraggingIntoCommitted: () -> Void

    @Binding var mapOpacityCommitted: Double
    @Binding var mapOpacityLive: Double?

    /// Called from **`DragGesture.onChanged`** in browse mode; parent must apply **`largeImage`** policy (see **`browsingRasterOpacitySyncBagAndRedraw`**).
    var redrawBrowsingMapRaster: (Double) -> Void
    /// Typically called from **`DragGesture.onEnded`** so **`largeImage`** rasters consume the new **`committed`** value.
    var finalizeBrowsingOpacity: (Double?) -> Void

    private static let expandedHeight: CGFloat = 160
    private let handleDiameter: CGFloat = 32

    /// `(capsuleWidth - handleDiameter) / 2` — reused as vertical end padding so handle travel stays centered.
    private var lateralInset: CGFloat {
        max(0, (MapControlChrome.diameter - handleDiameter) / 2)
    }

    /// Icon size aligned with **`chromeIconButton(..., fontSize: 22)`** on the collapsed chip.
    private var collapsedChipIconSize: CGFloat { 22 }

    private var unfoldedHandleGlyphSize: CGFloat { 14 }

    private let opacityIconSystemName = "circle.lefthalf.filled"

    /// Unfolded track vs collapsed chip: same width; height animates between **`diameter`** and **`expandedHeight`**.
    private var capsuleHeight: CGFloat {
        if isEditing { return Self.expandedHeight }
        return browserCollapsed ? MapControlChrome.diameter : Self.expandedHeight
    }

    private var capsuleAllowsDirectInteraction: Bool {
        isEditing || !browserCollapsed
    }

    var body: some View {
        ZStack {
            MapControlChrome.glassCapsuleFrame(width: MapControlChrome.diameter, height: capsuleHeight) {
                opacityDragSurface(
                    opacity: isEditing ? draftWarpSliderBinding() : browsingOpacityBinding(),
                    onDragChanged: isEditing ? nil : { alpha in redrawBrowsingMapRaster(alpha) },
                    onDragEnded: { alpha in
                        if isEditing {
                            finalizeDraftDraggingIntoCommitted()
                        } else {
                            finalizeBrowsingOpacity(alpha)
                        }
                    }
                )
            }
            .allowsHitTesting(capsuleAllowsDirectInteraction)

            if !isEditing && browserCollapsed {
                Color.clear
                    .frame(width: MapControlChrome.diameter, height: capsuleHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        browserCollapsed = false
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: browserCollapsed)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
        .contextMenu {
            if !isEditing && !browserCollapsed {
                Button("Collapse slider") {
                    finalizeBrowsingOpacity(nil)
                    browserCollapsed = true
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isEditing ? "Draft overlay opacity" : "Overlay opacity")
        .accessibilityValue("\(Int(displayedAccessibilityOpacity * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            if isEditing {
                switch direction {
                case .increment:
                    draftOpacityCommitted = (draftOpacityCommitted + step).clamped(to: 0...1)
                    draftOpacityDragging = nil
                case .decrement:
                    draftOpacityCommitted = (draftOpacityCommitted - step).clamped(to: 0...1)
                    draftOpacityDragging = nil
                @unknown default: break
                }
            } else {
                switch direction {
                case .increment:
                    let next = (mapOpacityCommitted + step).clamped(to: 0...1)
                    mapOpacityCommitted = next
                    mapOpacityLive = nil
                    finalizeBrowsingOpacity(next)
                case .decrement:
                    let next = (mapOpacityCommitted - step).clamped(to: 0...1)
                    mapOpacityCommitted = next
                    mapOpacityLive = nil
                    finalizeBrowsingOpacity(next)
                @unknown default: break
                }
            }
        }
    }

    private var displayedAccessibilityOpacity: Double {
        if isEditing { return (draftOpacityDragging ?? draftOpacityCommitted).clamped(to: 0...1) }
        return (mapOpacityLive ?? mapOpacityCommitted).clamped(to: 0...1)
    }

    private func draftWarpSliderBinding() -> Binding<Double> {
        Binding(
            get: { (draftOpacityDragging ?? draftOpacityCommitted).clamped(to: 0...1) },
            set: { draftOpacityDragging = $0.clamped(to: 0...1) }
        )
    }

    private func browsingOpacityBinding() -> Binding<Double> {
        Binding(
            get: { (mapOpacityLive ?? mapOpacityCommitted).clamped(to: 0...1) },
            set: { mapOpacityLive = $0.clamped(to: 0...1) }
        )
    }

    /// Draggable knob: vertical padding along the capsule equals **`lateralInset * progress`** on each side of the knob at full height.
    @ViewBuilder
    private func opacityDragSurface(
        opacity: Binding<Double>,
        onDragChanged: ((Double) -> Void)?,
        onDragEnded: ((Double) -> Void)?
    ) -> some View {
        GeometryReader { geo in
            let heightRange = Self.expandedHeight - MapControlChrome.diameter
            let progress: CGFloat = heightRange > 0
                ? min(max((geo.size.height - MapControlChrome.diameter) / heightRange, 0), 1)
                : 1
            let inset = lateralInset * progress
            let handleSize = MapControlChrome.diameter * (1 - progress) + handleDiameter * progress
            let visualIconPoints = collapsedChipIconSize * (1 - progress) + unfoldedHandleGlyphSize * progress
            let iconScale = visualIconPoints / collapsedChipIconSize
            let travel = max(0, geo.size.height - handleSize - inset * 2)
            let half = inset + handleSize / 2
            let alpha = opacity.wrappedValue.clamped(to: 0...1)
            let yCenter = travel < 0.5 ? geo.size.height / 2 : half + CGFloat(1 - alpha) * travel
            let handleFillOpacity = 0.14 * Double(progress)

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard travel >= 0.5 else { return }
                                let y = min(max(value.location.y, half), geo.size.height - half)
                                let next = Double(1 - (y - half) / travel).clamped(to: 0...1)
                                opacity.wrappedValue = next
                                onDragChanged?(next)
                            }
                            .onEnded { value in
                                guard travel >= 0.5 else { return }
                                let y = min(max(value.location.y, half), geo.size.height - half)
                                let next = Double(1 - (y - half) / travel).clamped(to: 0...1)
                                opacity.wrappedValue = next
                                onDragEnded?(next)
                            }
                    )
                Circle()
                    .fill(Color.primary.opacity(handleFillOpacity))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                            .opacity(Double(progress))
                    )
                    .frame(width: handleSize, height: handleSize)
                    .allowsHitTesting(false)
                    .overlay {
                        Image(systemName: opacityIconSystemName)
                            .font(.system(size: collapsedChipIconSize, weight: .regular))
                            .foregroundStyle(.primary)
                            .scaleEffect(iconScale)
                    }
                    .position(x: geo.size.width / 2, y: yCenter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
