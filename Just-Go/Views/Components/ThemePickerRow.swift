import SwiftUI

/// The app's colour choice as one row of swatches, shared by Settings and onboarding so the two
/// cannot disagree about the selection. Writes the `selectedThemeHex` key directly: every screen
/// reads that one key.
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
        // Four swatches fit the narrowest phone, so the row scrolls only when Dynamic Type widens
        // the labels.
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
        // The checkmark is inside the fill, where VoiceOver cannot see it.
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
