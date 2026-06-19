import SwiftUI

struct RouteDetailView: View {
    private let initialRoute: Route
    let preference: RoutePreference
    let alternatives: [Route]
    let tripAnchor: TripTimeAnchor
    @State var selectedRouteID: UUID
    @State var showRouteReport = false
    @State var showTripNote = false
    @State var showExpandedRouteMap = false
    @State var showLiveGo = false
    @State private var reminderScheduled = false
    @State private var showReminderDenied = false
    @State private var showReminderTooLate = false
    @State var tripNote = ""
    @State var routeReportNote = ""
    @State var routeReportSeverity: AccessibilityReportSeverity = .medium
    @State var metroNetworks: [MetroNetwork] = []
    @State var selectedTransferSegment: RouteSegment?
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @Environment(AccessibilityReportService.self) var accessibilityReportService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if alternatives.count > 1 {
                    RouteTabs(routes: alternatives, selection: $selectedRouteID)
                }
                routeSummaryCard
                if let departurePlan { DeparturePlanBanner(plan: departurePlan) }
                ServiceStatusBanner(status: route.serviceStatus)
                tripConfidenceCard
                routeMapPreview
                accessGuidanceCard
                if comfortForecast.hasSignal { RouteComfortCard(forecast: comfortForecast) }
                routeFeasibilityCard
                segmentsTimeline
                liveGoButton
                reminderSection
                riderTrustActions
            }
            .padding()
        }
        .navigationTitle(AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRouteReport) {
            routeReportSheet
        }
        .sheet(isPresented: $showTripNote) {
            tripNoteSheet
        }
        .sheet(item: $selectedTransferSegment) { segment in
            TransferStationSheet(
                transferSegment: segment,
                nextTransitSegment: nextTransitSegment(after: segment),
                cityID: route.networkCityID ?? appState.selectedCity?.id ?? "",
                crowdControl: route.crowdControl
            )
        }
        .fullScreenCover(isPresented: $showExpandedRouteMap) {
            FullScreenRouteMapView(route: route, metroNetworks: metroNetworks)
        }
        .fullScreenCover(isPresented: $showLiveGo) {
            LiveGoView(plan: LiveGoTripBuilder().plan(for: route))
        }
        .onChange(of: selectedRouteID) { _, _ in
            reminderScheduled = false
        }
        .task(id: route.networkCityID ?? appState.selectedCity?.id) {
            guard let cityID = route.networkCityID ?? appState.selectedCity?.id,
                  let network = await container.metroNetworkProvider.network(for: cityID) else {
                metroNetworks = []
                return
            }
            metroNetworks = [network]
        }
    }

    init(
        route: Route,
        preference: RoutePreference = .fastest,
        alternatives: [Route] = [],
        tripAnchor: TripTimeAnchor = .now
    ) {
        initialRoute = route
        self.preference = preference
        self.alternatives = alternatives.contains(where: { $0.id == route.id })
            ? alternatives
            : [route] + alternatives
        self.tripAnchor = tripAnchor
        _selectedRouteID = State(initialValue: route.id)
    }

    var route: Route {
        alternatives.first { $0.id == selectedRouteID } ?? initialRoute
    }

    func nextTransitSegment(after transferSegment: RouteSegment) -> RouteSegment? {
        guard let idx = route.segments.firstIndex(where: { $0.id == transferSegment.id }) else { return nil }
        return route.segments[(idx + 1)...].first { $0.type.isTransit }
    }

    private var routeMapPreview: some View {
        TransitMapView(
            visibleRegion: .constant(route.previewRegion),
            stations: [],
            metroNetworks: metroNetworks,
            route: route,
            showsUserLocation: false,
            onRegionChanged: nil,
            onStationSelected: { _ in }
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
                .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if !metroNetworks.isEmpty {
                MetroGeometryAttributionView()
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            showExpandedRouteMap = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(AppLocalization.localized("Open route map full screen"))
    }

    private var routeSummaryCard: some View {
        GlassCard {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.origin)
                            .font(.headline)
                        Text(AppLocalization.localized("Origin"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(route.destination)
                            .font(.headline)
                        Text(AppLocalization.localized("Destination"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(spacing: 20) {
                    StatItem(title: AppLocalization.localized("Duration"), value: route.formattedDuration, icon: "clock")
                    StatItem(title: AppLocalization.localized("Stops"), value: "\(route.totalStops)", icon: "tram")
                    StatItem(title: AppLocalization.localized("Transfers"), value: "\(route.transferCount)", icon: "arrow.triangle.2.circlepath")
                }

                if route.isFullyAccessible {
                    HStack {
                        Image(systemName: "figure.roll")
                            .foregroundStyle(.green)
                        Text(AppLocalization.localized("Fully Accessible Route"))
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.1), in: Capsule())
                }
            }
        }
    }

    private var tripConfidenceCard: some View {
        TripConfidenceCard(confidence: currentConfidence)
    }

    private var riderTrustActions: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Rider Notes"))
                    .font(.headline)

                Button {
                    tripNote = ""
                    showTripNote = true
                } label: {
                    Label(AppLocalization.localized("Mark complete or add trip note"), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    routeReportNote = ""
                    routeReportSeverity = .medium
                    showRouteReport = true
                } label: {
                    Label(AppLocalization.localized("Report route issue"), systemImage: "exclamationmark.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var tripTime: Date {
        TripTimeContext(anchor: tripAnchor, totalDuration: route.totalDuration).departureDate
    }

    private var comfortForecast: RouteComfortForecast {
        container.comfortForecastService.forecast(for: route.crowdControl, tripTime: tripTime)
    }

    private var departurePlan: DeparturePlan? {
        route.departurePlan(anchor: tripAnchor)
    }

    private var liveGoButton: some View {
        Button {
            showLiveGo = true
        } label: {
            Label(
                AppLocalization.text(english: "Start step-by-step guide", simplified: "开始分步导航", traditional: "開始分步導航"),
                systemImage: "figure.walk.circle.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reminderSection: some View {
        if let departurePlan {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalization.text(english: "Leave-time reminder", simplified: "出发提醒", traditional: "出發提醒"))
                        .font(.headline)
                    Button {
                        Task { await scheduleReminder(plan: departurePlan) }
                    } label: {
                        Label(
                            reminderScheduled
                                ? AppLocalization.text(english: "Reminder set", simplified: "提醒已设置", traditional: "提醒已設定")
                                : AppLocalization.text(english: "Remind me to leave", simplified: "提醒我出发", traditional: "提醒我出發"),
                            systemImage: reminderScheduled ? "bell.fill" : "bell"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(reminderScheduled)
                }
            }
            .alert(
                AppLocalization.text(english: "Notifications are off", simplified: "通知已关闭", traditional: "通知已關閉"),
                isPresented: $showReminderDenied
            ) {
                Button(AppLocalization.localized("OK"), role: .cancel) {}
            } message: {
                Text(AppLocalization.text(
                    english: "Enable notifications in Settings to get a leave-time reminder.",
                    simplified: "请在设置中开启通知以接收出发提醒。",
                    traditional: "請在設定中開啟通知以接收出發提醒。"
                ))
            }
            .alert(
                AppLocalization.text(english: "Too late to remind", simplified: "已来不及提醒", traditional: "已來不及提醒"),
                isPresented: $showReminderTooLate
            ) {
                Button(AppLocalization.localized("OK"), role: .cancel) {}
            } message: {
                Text(AppLocalization.text(
                    english: "The leave time is already here — no reminder was set.",
                    simplified: "出发时间已到，未设置提醒。",
                    traditional: "出發時間已到，未設定提醒。"
                ))
            }
        }
    }

    private func scheduleReminder(plan: DeparturePlan) async {
        guard plan.leaveByDate.addingTimeInterval(-5 * 60) > Date() else {
            showReminderTooLate = true
            return
        }
        guard await container.tripReminderService.requestAuthorization() else {
            showReminderDenied = true
            return
        }
        let scheduled = await container.tripReminderService.scheduleReminder(routeID: route.id, plan: plan, leadMinutes: 5)
        reminderScheduled = scheduled
        showReminderTooLate = !scheduled
    }

    var currentFeasibility: RouteFeasibility {
        container.routeFeasibilityService.feasibility(
            for: route,
            personalReports: accessibilityReportService.reports(affecting: route),
            comfort: comfortForecast
        )
    }

    private var currentConfidence: RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: currentFeasibility,
            preference: preference,
            alternatives: alternatives,
            comfort: comfortForecast
        )
    }
}
