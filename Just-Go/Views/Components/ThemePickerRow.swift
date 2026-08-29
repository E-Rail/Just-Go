import SwiftUI

/// The app's colour choice, as one horizontal row of swatches.
///
/// Extracted from `SettingsView` when onboarding gained the same control. One implementation for
/// both on purpose: the station sheet and the transfer sheet each grew their own copy of an
/// access-point row once, drifted, and shipped blank rows. A picker that disagrees with itself
/// about which colour is selected is the same class of bug.
///
/// Writes `selectedThemeHex` directly rather than taking a binding: every screen that reads the
/// theme reads that one `@AppStorage` key, so a binding would just be a second path to the same
/// value and a chance for the two to disagree.
struct ThemePickerRow: View {
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue

    var swatchSize: CGFloat = 44

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(AppTheme.allCases) { theme in
                    swatch(for: theme)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }
        // Four swatches fit on the narrowest phone, so the row only scrolls if Dynamic Type makes
        // the labels wide. Bouncing an already-fitting row reads as broken.
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func swatch(for theme: AppTheme) -> some View {
        let isSelected = selectedThemeHex == theme.rawValue
        Button {
            selectedThemeHex = theme.rawValue
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: swatchSize, height: swatchSize)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: swatchSize * 0.36, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(
                    Circle()
                        .stroke(isSelected ? theme.accent : Color.clear, lineWidth: 2.5)
                        .padding(-3)
                )
                Text(theme.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
        // The checkmark is the only thing distinguishing the selected swatch, and it is inside the
        // fill where VoiceOver cannot see it.
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
