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

/// Lets the rider plan around "Leave now / Leave by / Arrive by".
///
/// One row, opening a menu — not a headline sentence over a three-way segmented control. Almost
/// every search leaves this on "Leave now", and asking "When are you traveling?" in prose spent the
/// height of a route card restating what the control below it already said.
struct DeparturePlannerSection: View {
    @Binding var anchor: TripTimeAnchor

    @State private var mode: Mode = .now
    @State private var date = Date()

    enum Mode: CaseIterable, Identifiable {
        case now, departBy, arriveBy
        var id: Self { self }
        var title: String {
            switch self {
            case .now: return AppLocalization.text(english: "Leave now", simplified: "现在出发", traditional: "現在出發")
            case .departBy: return AppLocalization.text(english: "Leave by", simplified: "出发时间", traditional: "出發時間")
            case .arriveBy: return AppLocalization.text(english: "Arrive by", simplified: "到达时间", traditional: "抵達時間")
            }
        }

        var icon: String {
            switch self {
            case .now: return "figure.walk.departure"
            case .departBy: return "clock"
            case .arriveBy: return "flag.checkered"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(Mode.allCases) { option in
                    Button { mode = option } label: {
                        Label(option.title, systemImage: option.icon)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // `Color.primary`, not `.primary`: inside a `Menu` the hierarchical style
                    // resolves against the menu's tint, which rendered the row's own label in the
                    // accent colour as though it were a link.
                    Text(mode.title)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }

            if mode != .now {
                Divider().padding(.leading, 56)
                DatePicker(
                    selection: $date,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text(mode.title)
                        .font(.body)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .cardSurface()
        .onAppear(perform: syncFromAnchor)
        .onChange(of: mode) { _, _ in syncToAnchor() }
        .onChange(of: date) { _, _ in syncToAnchor() }
    }

    private func syncFromAnchor() {
        switch anchor {
        case .now:
            mode = .now
        case .departBy(let value):
            mode = .departBy
            date = value
        case .arriveBy(let value):
            mode = .arriveBy
            date = value
        }
    }

    private func syncToAnchor() {
        // `date` is seeded once at view creation, so by the time the rider switches out of
        // "Leave now" it may already be in the past — clamp it forward before committing.
        let planned = max(date, Date())
        switch mode {
        case .now: anchor = .now
        case .departBy: anchor = .departBy(planned)
        case .arriveBy: anchor = .arriveBy(planned)
        }
    }
}
