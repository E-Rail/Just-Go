import SwiftUI

/// The Back / Next pair at the foot of guidance. Stacks vertically at accessibility sizes, where
/// two full-width buttons side by side stop fitting.
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
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

/// Chrome for the primary (Next / Done) step button.
struct StepPrimaryButtonLabel: View {
    let title: String
    let systemImage: String
    /// Raw hex, not `themeColor`: a solid fill under white text, which `Color.adaptive` would
    /// lighten in dark mode.
    let fillHex: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(hex: fillHex), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .foregroundStyle(.white)
    }
}

/// An `HStack` that becomes a `VStack` when the rider's text size makes two columns unreadable;
/// used by `StepControlPair` and the route card.
struct AdaptiveStack<Content: View>: View {
    let isVertical: Bool
    var spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isVertical {
            VStack(alignment: .leading, spacing: spacing, content: content)
        } else {
            HStack(alignment: .top, spacing: spacing, content: content)
        }
    }
}
