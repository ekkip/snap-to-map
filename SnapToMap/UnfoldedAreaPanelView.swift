import SwiftUI

struct AreaPanelGridMetrics {
    let columns: Int
    let cellWidth: CGFloat
    let imageSize: CGFloat
    let cellHeight: CGFloat
    let spacing: CGFloat
    let horizontalPadding: CGFloat

    static let maxCellWidth: CGFloat = 200
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    static let labelSpacing: CGFloat = 6
    static let labelHeight: CGFloat = 22
    static let titleToGridGap: CGFloat = 22
    static let selectionRingPadding: CGFloat = 5
    static let gridBottomPadding: CGFloat = 16
    /// Visible slice of the second row in the basic detent.
    static let secondRowPeekFraction: CGFloat = 0.18

    init(containerWidth: CGFloat) {
        horizontalPadding = Self.horizontalPadding
        spacing = Self.spacing
        let available = max(containerWidth - horizontalPadding * 2, 1)
        columns = max(1, Int(ceil(available / Self.maxCellWidth)))
        cellWidth = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        imageSize = cellWidth
        cellHeight = imageSize + 2 * Self.selectionRingPadding + Self.labelSpacing + Self.labelHeight
    }

    var basicGridViewportHeight: CGFloat {
        cellHeight + spacing + Self.secondRowPeekFraction * cellHeight
    }

    /// Title row layout height (grabber + title + gap before grid).
    static var headerLayoutHeight: CGFloat {
        8 + 4 + 12 + 24 + titleToGridGap
    }

    func basicPanelHeight() -> CGFloat {
        Self.headerLayoutHeight + basicGridViewportHeight
    }

    /// `screenHeight` is the overlay canvas (safe-area top → physical bottom when bottom safe area is ignored).
    func fullPanelHeight(screenHeight: CGFloat) -> CGFloat {
        max(screenHeight, basicPanelHeight())
    }

    func fullGridViewportHeight(screenHeight: CGFloat) -> CGFloat {
        fullPanelHeight(screenHeight: screenHeight) - Self.headerLayoutHeight
    }
}

struct UnfoldedAreaPanelView: View {
    enum Detent: Equatable {
        case basic
        case full
    }

    private static let detentAnimation = Animation.easeInOut(duration: 0.28)
    private static let detentAnimationDuration: TimeInterval = 0.28

    let items: [OverlayItem]
    let screenSize: CGSize
    let topSafeInset: CGFloat
    let bottomSafeInset: CGFloat
    @Binding var detent: Detent
    let activatedOverlayID: UUID?
    var namespace: Namespace.ID
    var onActivate: (OverlayItem) -> Void
    var onCollapseToDescription: () -> Void

    @State private var scrollContentMinY: CGFloat = 0

    private var metrics: AreaPanelGridMetrics {
        AreaPanelGridMetrics(containerWidth: screenSize.width)
    }

    /// Full detent only when a second row exists.
    private var canExpandToFull: Bool {
        items.count > metrics.columns
    }

    private var fullPanelHeight: CGFloat {
        metrics.fullPanelHeight(screenHeight: screenSize.height)
    }

    /// Visible slice at the bottom edge; inner content stays at `fullPanelHeight`.
    private var visiblePanelHeight: CGFloat {
        switch detent {
        case .basic:
            return metrics.basicPanelHeight()
        case .full:
            return fullPanelHeight
        }
    }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 30,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 30,
            style: .continuous
        )
    }

    private var isScrollAtTop: Bool {
        scrollContentMinY >= -2
    }

    var body: some View {
        panelContent
            .frame(height: fullPanelHeight, alignment: .top)
            .modifier(AnimatedDetentViewportModifier(visibleHeight: visiblePanelHeight))
            .clipShape(panelShape)
            .onChange(of: items.count) { _, _ in
                guard detent == .full, !canExpandToFull else { return }
                detent = .basic
            }
    }

    private var panelContent: some View {
        gridCollection
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                panelBackground
                    .matchedGeometryEffect(id: "areaPanelSurface", in: namespace)
            }
    }

    private var gridHeaderInset: some View {
        VStack(spacing: 0) {
            panelHeader
            Color.clear
                .frame(height: AreaPanelGridMetrics.titleToGridGap)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background { panelHeaderSurface }
    }

    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            areaPanelGrabber
                .matchedGeometryEffect(id: "areaPanelGrabber", in: namespace)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
            Text("This area")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, metrics.horizontalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(CollectionDetentDragModifier(detent: detent, gesture: collectionDetentDragGesture))
    }

    @ViewBuilder
    private var panelHeaderSurface: some View {
        Group {
            if #available(iOS 26.0, *) {
                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.regular, in: Rectangle())
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .mask(headerBlurGradient)
    }

    private var headerBlurGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.5),
                .init(color: .black, location: 1)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private var gridCollection: some View {
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: metrics.spacing),
            count: metrics.columns
        )

        return ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: detent == .full && canExpandToFull) {
                overlayGrid(columns: columns)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: AreaPanelScrollOffsetKey.self,
                                value: proxy.frame(in: .named("areaPanelScroll")).minY
                            )
                        }
                    }
                    .id("areaPanelGridTop")
            }
            .coordinateSpace(name: "areaPanelScroll")
            .safeAreaInset(edge: .top, spacing: 0) {
                gridHeaderInset
            }
            .scrollDisabled(detent != .full || !canExpandToFull)
            .modifier(CollectionDetentDragModifier(detent: detent, gesture: collectionDetentDragGesture))
            .onPreferenceChange(AreaPanelScrollOffsetKey.self) { scrollContentMinY = $0 }
            .onChange(of: detent) { _, newDetent in
                guard newDetent == .basic else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.detentAnimationDuration) {
                    resetScrollToTop(using: scrollProxy)
                }
            }
        }
    }

    private func overlayGrid(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: metrics.spacing) {
            ForEach(items) { item in
                overlayGridCell(item)
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, AreaPanelGridMetrics.selectionRingPadding)
        .padding(.bottom, AreaPanelGridMetrics.selectionRingPadding + bottomSafeInset + AreaPanelGridMetrics.gridBottomPadding)
    }

    private func overlayGridCell(_ item: OverlayItem) -> some View {
        let imageSize = metrics.imageSize
        let ringPadding = AreaPanelGridMetrics.selectionRingPadding
        let thumbFrame = imageSize + ringPadding * 2
        return Button {
            onActivate(item)
        } label: {
            VStack(alignment: .leading, spacing: AreaPanelGridMetrics.labelSpacing) {
                ZStack {
                    OverlayPanelThumbnailView(item: item, thumbnailSize: imageSize)
                    if item.id == activatedOverlayID {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.blue, lineWidth: 4)
                            .frame(width: thumbFrame, height: thumbFrame)
                    }
                }
                .frame(width: thumbFrame, height: thumbFrame, alignment: .leading)

                Text(item.resolvedDisplayName)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: metrics.cellWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(iOS 26.0, *) {
            panelShape
                .fill(Color.clear)
                .glassEffect(.regular, in: panelShape)
        } else {
            panelShape
                .fill(.ultraThinMaterial)
                .overlay(panelShape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        }
    }

    private var areaPanelGrabber: some View {
        Capsule()
            .fill(Color.primary.opacity(0.35))
            .frame(width: 40, height: 4)
    }

    private func resetScrollToTop(using scrollProxy: ScrollViewProxy) {
        scrollContentMinY = 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollProxy.scrollTo("areaPanelGridTop", anchor: .top)
        }
        DispatchQueue.main.async {
            var retry = Transaction()
            retry.disablesAnimations = true
            withTransaction(retry) {
                scrollProxy.scrollTo("areaPanelGridTop", anchor: .top)
            }
        }
    }

    private var collectionDetentDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let dy = value.translation.height
                withAnimation(Self.detentAnimation) {
                    switch detent {
                    case .basic:
                        if dy > 24 {
                            onCollapseToDescription()
                        } else if dy < -24, canExpandToFull {
                            detent = .full
                        }
                    case .full:
                        guard isScrollAtTop, dy > 24 else { return }
                        detent = .basic
                    }
                }
            }
    }
}

/// Full-size panel content slides within a bottom-anchored viewport as detent changes.
private struct AnimatedDetentViewportModifier: AnimatableModifier {
    var visibleHeight: CGFloat

    var animatableData: CGFloat {
        get { visibleHeight }
        set { visibleHeight = newValue }
    }

    func body(content: Content) -> some View {
        Color.clear
            .frame(height: max(visibleHeight, 0))
            .overlay(alignment: .top) {
                content
            }
            .clipped()
    }
}

private struct AreaPanelScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CollectionDetentDragModifier<G: Gesture>: ViewModifier {
    let detent: UnfoldedAreaPanelView.Detent
    let gesture: G

    func body(content: Content) -> some View {
        if detent == .basic {
            content.highPriorityGesture(gesture)
        } else {
            content.simultaneousGesture(gesture)
        }
    }
}

private struct OverlayPanelThumbnailView: View {
    let item: OverlayItem
    let thumbnailSize: CGFloat

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: item.id) {
            let overlay = item
            let loaded = await Task.detached(priority: .userInitiated) {
                OverlayLibrary.panelThumbnail(for: overlay, maxPixelDimension: 256)
            }.value
            thumbnail = loaded
        }
    }
}
