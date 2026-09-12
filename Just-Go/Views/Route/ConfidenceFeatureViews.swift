import CoreLocation
import SwiftUI

extension Route {
    /// The hail this route would need, when both ends were actually drawn.
    var hailRequest: ServiceStatusBanner.Hail? {
        guard let origin = groundOrigin, let target = groundDestination else { return nil }
        return ServiceStatusBanner.Hail(
            origin: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude),
            destination: CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude),
            // `self.`, because the guard above shadows `origin` with the coordinate it unwrapped.
            originName: self.origin,
            destinationName: destination
        )
    }
}

extension RouteServiceStatus {
    var uiColor: Color {
        switch self {
        case .running: return .green
        case .lastTrainSoon: return .orange
        case .serviceEndedToday: return .red
        case .notYetStarted: return .blue
        case .unknown: return .gray
        }
    }

    var iconName: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .lastTrainSoon: return "exclamationmark.circle.fill"
        case .serviceEndedToday: return "moon.zzz.fill"
        case .notYetStarted: return "sunrise.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Compact service-hours banner ("Last train in N min" / "Service ended" / "Starts 5:30").
struct ServiceStatusBanner: View {
    let status: RouteServiceStatus
    var compact = false
    /// What a taxi over the same ground costs at this hour, when the trip is against the clock.
    ///
    /// The warning above it is a fact about the trains. This is the fact about the rider's wallet,
    /// and for someone finishing a late shift it is the one that decides whether they run.
    var missedTrainTaxiYuan: Double?
    /// Where a car would have to go, when one is worth offering. `nil` leaves the price as a fact
    /// with nothing attached to it, which is what shipped.
    var hail: Hail?

    /// The two ends of the journey, for handing to a hailing app.
    struct Hail: Equatable {
        let origin: CLLocationCoordinate2D
        let destination: CLLocationCoordinate2D
        /// Both ends are named. DiDi itself never reads the start's name, but
        /// `ExternalRouteHandoff.open` asks every destination for one — Apple Maps drops a start it
        /// cannot label — and a parameter only half the call sites fill is how they drift apart.
        let originName: String
        let destinationName: String

        static func == (lhs: Hail, rhs: Hail) -> Bool {
            lhs.origin.latitude == rhs.origin.latitude &&
                lhs.origin.longitude == rhs.origin.longitude &&
                lhs.destination.latitude == rhs.destination.latitude &&
                lhs.destination.longitude == rhs.destination.longitude &&
                lhs.originName == rhs.originName &&
                lhs.destinationName == rhs.destinationName
        }
    }

    var body: some View {
        if let text = status.bannerText {
            VStack(alignment: .leading, spacing: 4) {
                Label(text, systemImage: status.iconName)
                    .font(compact ? .caption : .subheadline)
                    .fontWeight(.medium)
                if let taxi = missedTrainTaxiYuan {
                    Text(taxiText(taxi))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    hailButton
                }
            }
            .foregroundStyle(status.uiColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 8 : 12)
            .background(status.uiColor.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    /// Offered only when the app is actually installed, and only beside a price.
    ///
    /// The app has already decided a taxi is the answer here — it checked the last train, found it
    /// gone or nearly gone, and priced the drive. Stopping at the number and making the rider
    /// retype their destination into another app is where it stopped being useful. DiDi has been
    /// in `ExternalRouteHandoff` and in `LSApplicationQueriesSchemes` since the bike and car legs
    /// shipped; this is the same handoff for the one case that most deserves it.
    ///
    /// No web fallback here on purpose. Elsewhere a fallback opens a map page that is still worth
    /// reading; a rider who does not have the hailing app cannot hail from this button, and a link
    /// pretending otherwise is worse than no button.
    @ViewBuilder
    private var hailButton: some View {
        if let hail, ExternalRouteHandoff.destinations(for: .driving).contains(.didi) {
            Button {
                ExternalRouteHandoff.open(
                    .didi,
                    from: hail.origin,
                    originName: hail.originName,
                    to: hail.destination,
                    destinationName: hail.destinationName,
                    mode: .driving
                )
            } label: {
                Label(
                    AppLocalization.text(english: "Get a DiDi", simplified: "叫滴滴", traditional: "叫滴滴"),
                    systemImage: "car.fill"
                )
                .font(.caption)
                .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .frame(minHeight: Metrics.minimumTapTarget)
            .padding(.top, 2)
        }
    }

    /// "About" throughout, because it is a tariff estimate over a driving route rather than a
    /// metered ride anyone has taken.
    private func taxiText(_ yuan: Double) -> String {
        let fare = RouteFare.formatted(yuan)
        return AppLocalization.text(
            english: "A taxi instead is about \(fare).",
            simplified: "改乘出租车约 \(fare)。",
            traditional: "改乘計程車約 \(fare)。"
        )
    }
}

/// "Leave by / arrive by" banner with last-train context.
struct DeparturePlanBanner: View {
    let plan: DeparturePlan

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(plan.leaveByHeadline, systemImage: "figure.walk")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(plan.arriveByDetail)
                    .rowMeta()
                if let last = plan.lastTrainDetail {
                    Label(last, systemImage: "tram")
                        .font(.caption)
                        .foregroundStyle(lastTrainColor)
                }
            }
        }
    }

    private var lastTrainColor: Color {
        switch plan.lastTrainStatus {
        case .missed: return .red
        case .tight: return .orange
        case .notStarted: return .blue
        default: return .secondary
        }
    }
}
