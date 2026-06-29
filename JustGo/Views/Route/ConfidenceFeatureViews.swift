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

extension RouteComfortLevel {
    var uiColor: Color {
        switch self {
        case .comfortable: return .green
        case .moderate: return .orange
        case .busy: return .red
        case .unknown: return .gray
        }
    }

    var iconName: String {
        switch self {
        case .comfortable: return "person.fill"
        case .moderate: return "person.2.fill"
        case .busy: return "person.3.fill"
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
                .background(status.uiColor.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 8 : 12))
                .accessibilityLabel(text)
        }
    }
}

/// Crowding / comfort forecast card.
struct RouteComfortCard: View {
    let forecast: RouteComfortForecast

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(forecast.summaryTitle, systemImage: forecast.level.iconName)
                    .font(.headline)
                    .foregroundStyle(forecast.level.uiColor)

                ForEach(forecast.detailLines, id: \.self) { line in
                    Label(line, systemImage: "person.2.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(AppLocalization.text(
                    english: "Crowding estimate from official windows and typical peak times, not a live measurement.",
                    simplified: "拥挤情况根据官方限流时段与常规高峰估算，非实时数据。",
                    traditional: "擁擠情況根據官方限流時段與常規尖峰估算，非即時數據。"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// Picker that lets the rider plan around "Leave now / Leave by / Arrive by".
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text(english: "When are you traveling?", simplified: "何时出行？", traditional: "何時出行？"))
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(AppLocalization.text(english: "When are you traveling?", simplified: "何时出行？", traditional: "何時出行？"))

            if mode != .now {
                DatePicker(
                    selection: $date,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text(mode.title)
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
