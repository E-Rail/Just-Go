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

    var body: some View {
        if let text = status.bannerText {
            Label(text, systemImage: status.iconName)
                .font(compact ? .caption : .subheadline)
                .fontWeight(.medium)
                .foregroundStyle(status.uiColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(compact ? 8 : 12)
                .background(status.uiColor.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
                .accessibilityLabel(text)
        }
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
