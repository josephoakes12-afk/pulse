import SwiftUI

enum DrawerMotion {
    static let reveal = Animation.smooth(duration: 0.34)
    static let numbers = Animation.easeInOut(duration: 0.2)
}

/// Keep the content laid out at its full width, including while collapsed.
/// Only the viewport changes size, so text never compresses or reflows.
struct DrawerReveal<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let maximumHeight: CGFloat = 240

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: DrawerContentHeight.self, value: geometry.size.height)
                    }
                }
                .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(!isExpanded || contentHeight <= maximumHeight)
        .modifier(DrawerViewport(progress: isExpanded ? 1 : 0, height: min(contentHeight, maximumHeight) + 16))
        .clipped()
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .onPreferenceChange(DrawerContentHeight.self) { height in
            guard height > 0, abs(height - contentHeight) > 0.5 else { return }
            // Initial measurement happens while closed, with no speculative
            // height. Later source changes resize an open drawer smoothly.
            withAnimation(contentHeight > 0 && isExpanded && !reduceMotion ? DrawerMotion.reveal : nil) {
                contentHeight = height
            }
        }
    }
}

private struct DrawerContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Interpolating a concrete height on every frame also lets the native popover
/// follow the reveal, rather than adopting its final size before it finishes.
private nonisolated struct DrawerViewport: AnimatableModifier {
    var progress: CGFloat
    var height: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, height) }
        set { progress = newValue.first; height = newValue.second }
    }

    func body(content: Content) -> some View {
        let amount = min(max(progress, 0), 1)
        content
            .opacity(min(amount * 1.5, 1))
            .frame(height: max(0, height) * amount, alignment: .top)
    }
}

/// Round the combined panel once, rather than rounding two drawers separately
/// while switching. Top placement keeps fractional content heights from moving
/// the header between pixel grids inside the native window.
nonisolated struct IntegralPanelLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height.rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
