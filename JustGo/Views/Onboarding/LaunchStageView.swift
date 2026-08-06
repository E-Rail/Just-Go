import SwiftUI

/// Shown instead of the tab UI while the essential launch stages run, so the wait reads as the
/// app preparing itself rather than as a stall. The caption names the stage in progress, which
/// is also how a slow launch on a real device gets attributed to a specific stage.
struct LaunchStageView: View {
    let stage: LaunchStage
    let progress: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue

    // Not a `Text("…")` literal on purpose: the app name is a wordmark, never translated, and
    // Scripts/validate_localizations.rb rejects bare English literals in `Text(...)`.
    private let wordmark = "JustGo"

    private var themeColor: Color {
        Color.adaptive(hex: selectedThemeHex)
    }

    var body: some View {
        VStack(spacing: 22) {
            Text(wordmark)
                // San Francisco, at the weight the system uses for a large title. The wordmark was
                // set in New York (`design: .serif`), which is also an Apple face but reads as a
                // reading typeface — the first thing the app shows should look like the platform
                // it is part of, and every other screen is already SF.
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 52 : 44, weight: .semibold))
                .foregroundStyle(themeColor)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                progressBar
                Text(stage.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stage.caption)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    /// Drawn rather than a `ProgressView(value:)` so the fill is exactly the theme colour at
    /// exactly this weight — the system bar renders its own track styling and cannot be pinned
    /// to a 3pt capsule.
    private var progressBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(themeColor.opacity(0.18))
                Capsule()
                    .fill(themeColor)
                    .frame(width: max(0, min(1, progress)) * width)
            }
        }
        .frame(width: 160, height: 3)
        .animation(.easeOut(duration: 0.25), value: progress)
    }
}
