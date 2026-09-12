import CoreLocation
import SwiftUI

/// The whole content of a bike or car leg: an invitation to finish it somewhere better.
///
/// Just-Go does not do live road navigation and will not pretend to. A cycling leg here is the
/// pedestrian route re-timed, and a driving leg is MapKit's road route with no traffic, no
/// restrictions and no parking — so on those legs an app that routes them properly is not a
/// footnote under a line this app drew. It *is* the answer, and it is presented as one.
///
/// Worded as an upgrade rather than an apology. "Just-Go can't guide you" tells the rider they
/// picked the wrong app; naming what will do it better is the same fact pointed forwards.
///
/// The destinations are **stacked**, one full-width row each, rather than crammed onto a single
/// line: each row is then a real target for a thumb, and the group reads as a choice rather than a
/// toolbar. Only installed apps appear — `destinations(for:)` drops the rest, so nothing here
/// offers a rider an app they do not have.
struct ExternalRouteHandoffCard: View {
    let mode: AccessLegMode
    let origin: CLLocationCoordinate2D
    let originName: String
    let target: CLLocationCoordinate2D
    let destinationName: String

    var body: some View {
        let destinations = ExternalRouteHandoff.destinations(for: mode)
        if !destinations.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.m) {
                HStack(alignment: .center, spacing: Metrics.m) {
                    Image(systemName: mode.symbolName)
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: Metrics.minimumTapTarget)
                    Text(AppLocalization.text(
                        english: "To give a better experience, please open in:",
                        simplified: "为了更好的体验，请在以下应用中打开：",
                        traditional: "為了更好的體驗，請在以下應用中開啟："
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // Wraps rather than truncating: at an accessibility text size this sentence is
                    // several lines, and it is the line that explains why the buttons are there.
                    .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(destinations) { destination in
                    Button {
                        ExternalRouteHandoff.open(
                            destination,
                            from: origin,
                            originName: originName,
                            to: target,
                            destinationName: destinationName,
                            mode: mode
                        )
                    } label: {
                        Label(destination.title, systemImage: destination.symbolName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle)
                }
            }
            .padding(.top, Metrics.s)
        }
    }
}
