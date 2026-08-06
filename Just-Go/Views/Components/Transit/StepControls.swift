import SwiftUI

/// The Back / Next pair at the foot of the step-by-step guidance screens (Live Go and the
/// indoor navigator). Stacks vertically at accessibility text sizes, where two full-width
/// buttons side by side stop fitting.
struct StepControlPair<Back: View, Next: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var back: Back
    @ViewBuilder var next: Next

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                next
                back
            }
        } else {
            HStack(spacing: 14) {
                back
                next
            }
        }
    }
}

/// Chrome for the secondary (Back) step button.
struct StepSecondaryButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Chrome for the primary (Next / Done) step button.
struct StepPrimaryButtonLabel: View {
    let title: String
    let systemImage: String
    /// Raw hex, not `themeColor`: this is a solid fill under white text, and
    /// `Color.adaptive` lightens toward white in dark mode specifically for *foreground*
    /// legibility — used as a fill it collapses contrast instead.
    let fillHex: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(hex: fillHex), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(.white)
    }
}
