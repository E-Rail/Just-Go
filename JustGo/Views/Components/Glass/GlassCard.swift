import SwiftUI

struct GlassCard<Content: View>: View {
    let content: Content
    var material: Material = .ultraThinMaterial
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16

    init(
        material: Material = .ultraThinMaterial,
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.material = material
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }
}
