import SwiftUI

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
                }
            }
            .foregroundStyle(status.uiColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compact ? 8 : 12)
            .background(status.uiColor.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
            .accessibilityElement(children: .combine)
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
