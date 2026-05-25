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

struct GlassSheet<Content: View>: View {
    let content: Content
    var material: Material = .ultraThinMaterial

    init(
        material: Material = .ultraThinMaterial,
        @ViewBuilder content: () -> Content
    ) {
        self.material = material
        self.content = content()
    }

    var body: some View {
        content
            .padding()
            .background(material, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }
}

struct GlassButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .fontWeight(.medium)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
