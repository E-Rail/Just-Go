import CoreLocation
import SwiftUI

/// The content of a bike or car leg: the apps that route it properly. Just-Go does no live road
/// navigation (a cycling leg without a key is the re-timed pedestrian route; a driving leg is
/// MapKit's road route with no traffic or parking), so on these legs that app is the answer.
///
/// Worded as an upgrade, not an apology: a line of text, then a chip per installed app, wrapping
/// where they do not fit one line; `destinations(for:)` drops apps that are not installed. No glyph
/// of its own: the leg's marker, or the guidance step's, already says bike or car. No padding of
/// its own either: the caller's stack spaces it.
struct ExternalRouteHandoffCard: View {
    let mode: AccessLegMode
    let origin: CLLocationCoordinate2D
    let originName: String
    let target: CLLocationCoordinate2D
    let destinationName: String

    var body: some View {
        let destinations = ExternalRouteHandoff.destinations(for: mode)
        if !destinations.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.s) {
                Text(AppLocalization.text(
                    english: "To give a better experience, please open in:",
                    simplified: "为了更好的体验，请在以下应用中打开：",
                    traditional: "為了更好的體驗，請在以下應用中開啟："
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                // Wraps rather than truncating: at accessibility sizes this sentence explains why
                // the chips are there.
                .fixedSize(horizontal: false, vertical: true)

                ChipFlowLayout(spacing: Metrics.s) {
                    ForEach(destinations) { destination in
                        LegActionChip(
                            title: destination.title,
                            systemImage: destination.symbolName,
                            isProminent: true
                        ) {
                            ExternalRouteHandoff.open(
                                destination,
                                from: origin,
                                originName: originName,
                                to: target,
                                destinationName: destinationName,
                                mode: mode
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A chip under a leg that hands something to another app: the app's own chip (`chipSurface`), so it
/// is the size of every other chip. Its target reaches past what is drawn, above and below, to
/// about `Metrics.minimumTapTarget`, and is taken back out of the layout, so rows of chips sit a
/// chip's gap apart and a thumb still finds one.
struct LegActionChip: View {
    let title: String
    let systemImage: String
    /// The leg's answer (an app that navigates it) rather than a help beside it.
    var isProminent = false
    let action: () -> Void

    private static let reach: CGFloat = 6

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .chipSurface(isProminent: isProminent)
            .padding(.vertical, Self.reach)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -Self.reach)
    }
}
