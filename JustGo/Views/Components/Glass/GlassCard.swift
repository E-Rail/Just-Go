import SwiftUI

/// The app's type ramp, as three names instead of 180 hand-picked `.font()` calls.
///
/// Better than half the text in this app was `.caption` or smaller, and rows routinely drew the
/// *label* larger than the value it introduced — "Exit" at `.subheadline` semibold over the exit's
/// actual name at `.caption` secondary. Naming the three roles makes that inversion impossible to
/// write by accident and makes a later sweep mechanical.
///
/// `.rowTitle` names a thing. `.rowValue` is the thing — never smaller than its title. `.rowMeta`
/// is genuine metadata (a count, a source, a timestamp) and is the only one allowed to be small.
extension View {
    func rowTitle() -> some View {
        font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary)
    }

    func rowValue() -> some View {
        font(.body)
    }

    func rowMeta() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.035), radius: 4, y: 1)
    }
}
