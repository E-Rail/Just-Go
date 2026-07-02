import SwiftUI

extension View {
    /// Presents `content` for a bound `Identifiable?` item as a full-screen page that slides
    /// in from the trailing edge, instead of a bottom sheet. Mirrors
    /// `.sheet(item:onDismiss:content:)`'s call signature so `.sheet(item:)` call sites can
    /// switch with close to a 1-line rename. Dismisses via a right-ward swipe (from anywhere,
    /// like a standard push-navigation pop) or the caller setting `item` back to `nil`.
    func rightSidePanel<Item: Identifiable, PanelContent: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> PanelContent
    ) -> some View {
        modifier(RightSidePanelModifier(item: item, onDismiss: onDismiss, panelContent: content))
    }
}

private struct RightSidePanelModifier<Item: Identifiable, PanelContent: View>: ViewModifier {
    @Binding var item: Item?
    var onDismiss: (() -> Void)?
    let panelContent: (Item) -> PanelContent

    // Mirrors `item`, but only ever mutated inside `withAnimation` here, so the slide
    // transition always plays even though call sites set `item` with a plain assignment.
    @State private var displayedItem: Item?
    @State private var dragTranslationX: CGFloat = 0

    private let transitionAnimation = Animation.easeInOut(duration: 0.28)

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let pageWidth = proxy.size.width
                    if let displayedItem {
                        panelContent(displayedItem)
                            .frame(width: pageWidth)
                            .frame(maxHeight: .infinity)
                            .background(Color.appBackground)
                            .ignoresSafeArea(edges: .vertical)
                            .offset(x: max(0, dragTranslationX))
                            .simultaneousGesture(dragToDismiss(pageWidth: pageWidth))
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .onChange(of: item?.id) { _, newID in
                if newID != nil {
                    withAnimation(transitionAnimation) {
                        dragTranslationX = 0
                        displayedItem = item
                    }
                } else {
                    withAnimation(transitionAnimation) { displayedItem = nil }
                    onDismiss?()
                }
            }
    }

    private func dismiss() {
        item = nil
    }

    private func dragToDismiss(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let horizontalDominant = abs(value.translation.width) > abs(value.translation.height)
                guard horizontalDominant, value.translation.width > 0 else { return }
                dragTranslationX = value.translation.width
            }
            .onEnded { value in
                let horizontalDominant = abs(value.translation.width) > abs(value.translation.height)
                let draggedFarEnough = value.translation.width > pageWidth * 0.3
                let flungFastEnough = value.predictedEndTranslation.width > pageWidth * 0.6
                if horizontalDominant && (draggedFarEnough || flungFastEnough) {
                    dismiss()
                } else {
                    withAnimation(.interactiveSpring()) { dragTranslationX = 0 }
                }
            }
    }
}
