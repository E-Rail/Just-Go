import CoreLocation
import SwiftUI

/// The content of a bike or car leg: the apps that route it properly. Just-Go does no live road
/// navigation (a cycling leg without a key is the re-timed pedestrian route; a driving leg is
/// MapKit's road route with no traffic or parking), so on these legs that app is the answer.
///
/// Worded as an upgrade, not an apology. One full-width row per installed app, so each is a real
/// thumb target; `destinations(for:)` drops apps that are not installed.
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
                        .foregroundStyle(Color(hex: mode.segmentType.colorHex(line: nil)))
                        .frame(width: Metrics.minimumTapTarget)
                    Text(AppLocalization.text(
                        english: "To give a better experience, please open in:",
                        simplified: "为了更好的体验，请在以下应用中打开：",
                        traditional: "為了更好的體驗，請在以下應用中開啟："
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // Wraps rather than truncating: at accessibility sizes this sentence explains
                    // why the buttons are there.
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
