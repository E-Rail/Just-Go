import SwiftUI
import CoreLocation

/// The two pushes this screen can make, unified so they share ONE
/// `navigationDestination(item:)` registration.
enum RouteDetailDestination: Hashable {
    case transfer(RouteSegment)
    case station(RouteStationStop)
}

struct RouteDetailView: View {
    private let initialRoute: Route
    let preference: RoutePreference
    let alternatives: [Route]
    let tripAnchor: TripTimeAnchor
    let accessibilityFilter: AccessibilityFilter
    @State var selectedRouteID: UUID
    @State var showTripNote = false
    @State var showExpandedRouteMap = false
    @State var showLiveGo = false
    @State private var scheduledReminderRouteID: UUID?
    @State var tripLoggedConfirmation = false
    @State private var showReminderDenied = false
    @State private var showReminderTooLate = false
    @State var tripNote = ""
    @State var detailDestination: RouteDetailDestination?
    @State private var boardingServiceWindows: [StationServiceWindow] = []
    // Raw theme hex for the "Navigate" button's solid fill — see RoutePlannerView's
    // identical declaration for why `Color.accentColor` (dark-mode-lightened for
    // foreground use) isn't used as a fill under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.forestGreen.rawValue
    // Once per detail instance, NOT reset on disappear: dismissing the auto-presented
    // navigator re-fires onAppear, and a reset would immediately re-present it.
    @State private var didAutoPresentLiveGo = false
    @Environment(DIContainer.self) private var container
    @Environment(AppState.self) var appState
    @Environment(TripMemoryService.self) var tripMemoryService
    @AppStorage("reminderLeadMinutes") private var reminderLeadMinutes = 5

    var body: some View {
        // Compute the feasibility → confidence chain once per render and pass the values down,
        // instead of letting each card recompute them (previously 2× feasibility/personal-reports
        // per body evaluation).
        let feasibility = currentFeasibility()
        let confidence = currentConfidence(feasibility: feasibility)
        return ScrollView {
            VStack(spacing: 20) {
                if alternatives.count > 1 {
                    RouteTabs(routes: alternatives, selection: $selectedRouteID)
                }
                routeDecisionHeader(feasibility: feasibility, confidence: confidence)
                if let departurePlan { DeparturePlanBanner(plan: departurePlan) }
                routeMapPreview
                segmentsTimeline
                stationsCard
                serviceHoursRow
                ServiceStatusBanner(status: route.serviceStatus)
                tripEssentialsCard
                accessGuidanceCard
                tripConfidenceCard(confidence)
                routeFeasibilityCard(feasibility)
                reminderSection
                riderTrustActions
            }
            .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(AppLocalization.localized("Route Details"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Step-by-Step Guidance (cognitive accessibility): go straight into the
            // guided navigator instead of the dense detail screen; dismissing it lands
            // on the full detail as usual.
            if appState.accessibilityPreference.stepByStepGuidance, !didAutoPresentLiveGo {
                didAutoPresentLiveGo = true
                ActiveTripStore.save(route)
                showLiveGo = true
            }
        }
        .sheet(isPresented: $showTripNote) {
            tripNoteSheet
        }
        // A single destination registration: two navigationDestination(item:) modifiers on
        // the same node is a historically unreliable SwiftUI pattern (one registration can
        // shadow the other), and both pushes share this screen anyway.
        .navigationDestination(item: $detailDestination) { destination in
            switch destination {
            case .transfer(let segment):
                TransferStationSheet(
                    transferSegment: segment,
                    nextTransitSegment: nextTransitSegment(after: segment),
                    cityID: route.networkCityID ?? appState.selectedCity?.id ?? "",
                    accessibilityFilter: accessibilityFilter
                )
            case .station(let stop):
                RouteStationGuideSheet(
                    stop: stop,
                    cityID: route.networkCityID ?? appState.selectedCity?.id ?? ""
                )
            }
        }
        .fullScreenCover(isPresented: $showExpandedRouteMap) {
            FullScreenRouteMapView(route: route)
        }
        .fullScreenCover(isPresented: $showLiveGo, onDismiss: { ActiveTripStore.clear() }) {
            LiveGoView(route: route)
        }
        .onChange(of: selectedRouteID) { _, _ in
            tripLoggedConfirmation = false
        }
        .onChange(of: routeSelectionSignature) {
            ensureSelectedRouteIsCurrent()
        }
        .task(id: "\(route.networkCityID ?? appState.selectedCity?.id ?? "")|\(selectedRouteID)") {
            boardingServiceWindows = []
            async let transferAssets: Void = container.officialStationData.prefetchTransferAssets(
                for: route
            )
            if let cityID = route.networkCityID ?? appState.selectedCity?.id {
                await loadServiceHours(cityID: cityID)
            }
            await transferAssets
        }
    }

    init(
        route: Route,
        preference: RoutePreference = .fastest,
        alternatives: [Route] = [],
        tripAnchor: TripTimeAnchor = .now,
        accessibilityFilter: AccessibilityFilter = .none
    ) {
        initialRoute = route
        self.preference = preference
        self.alternatives = alternatives.contains(where: { $0.id == route.id })
            ? alternatives
            : [route] + alternatives
        self.tripAnchor = tripAnchor
        self.accessibilityFilter = accessibilityFilter
        _selectedRouteID = State(initialValue: route.id)
    }

    var route: Route {
        alternatives.first { $0.id == selectedRouteID } ?? initialRoute
    }

    private var routeSelectionSignature: String {
        alternatives.map(\.id.uuidString).joined(separator: "|")
    }

    /// Derived from the single tracked route id so switching tabs to browse never silently
    /// drops a reminder the user set; "set" shows again when they return to that route.
    private var reminderScheduled: Bool {
        scheduledReminderRouteID == selectedRouteID
    }

    private func ensureSelectedRouteIsCurrent() {
        guard !alternatives.contains(where: { $0.id == selectedRouteID }),
              let firstRoute = alternatives.first else { return }
        selectedRouteID = firstRoute.id
    }

    func nextTransitSegment(after transferSegment: RouteSegment) -> RouteSegment? {
        guard let idx = route.segments.firstIndex(where: { $0.id == transferSegment.id }) else { return nil }
        return route.segments[(idx + 1)...].first { $0.type.isTransit }
    }

    private var routeMapPreview: some View {
        TransitMapView(
            visibleRegion: .constant(route.previewRegion),
            stations: [],
            metroNetworks: [],
            route: route,
            showsUserLocation: false,
            onRegionChanged: nil,
            onStationSelected: { _ in }
        )
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
                .padding(10)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            showExpandedRouteMap = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(AppLocalization.localized("Open route map full screen"))
    }

    private func routeDecisionHeader(
        feasibility: RouteFeasibility,
        confidence: RouteConfidence
    ) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(route.origin) → \(route.destination)")
                            .font(.headline)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Text(route.formattedDuration)
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(AppLocalization.text(
                                english: "\(route.totalStops) stops",
                                simplified: "\(route.totalStops)站",
                                traditional: "\(route.totalStops)站"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(route.formattedTransfers)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    DataConfidenceChip(confidence: decisionDataConfidence, compact: true)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        routeStatusChip(confidence.level.title, icon: confidenceIcon(for: confidence.level), tint: confidence.level.color)
                        routeStatusChip(feasibility.title, icon: feasibility.level.iconName, tint: feasibility.level.color)
                        if route.isFullyAccessible {
                            routeStatusChip(AppLocalization.localized("Fully Accessible Route"), icon: "figure.roll", tint: .green)
                        }
                    }
                }

                Button {
                    ActiveTripStore.save(route)
                    showLiveGo = true
                } label: {
                    Label(
                        AppLocalization.text(english: "Navigate", simplified: "开始导航", traditional: "開始導航"),
                        systemImage: "figure.walk.circle.fill"
                    )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color(hex: selectedThemeHex), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func routeStatusChip(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2)
            .fontWeight(.medium)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private var decisionDataConfidence: DataConfidence {
        let coverage = route.dataCoverage
        if coverage.scheduleConfidence == .official,
           coverage.accessibilityConfidence == .official,
           coverage.stationMapConfidence == .official {
            return .official
        }
        if coverage.hasOfficialCoreData {
            return .sourcePending
        }
        return .unavailable
    }

    private func confidenceIcon(for level: RouteConfidenceLevel) -> String {
        switch level {
        case .high:
            return "checkmark.seal.fill"
        case .medium:
            return "exclamationmark.triangle.fill"
        case .low:
            return "exclamationmark.octagon.fill"
        }
    }

    private func tripConfidenceCard(_ confidence: RouteConfidence) -> some View {
        TripConfidenceCard(confidence: confidence)
    }

    private var riderTrustActions: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.localized("Rider Notes"))
                    .font(.headline)

                if tripLoggedConfirmation {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            AppLocalization.text(english: "Trip logged", simplified: "行程已记录", traditional: "行程已記錄"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        .font(.subheadline)
                        if !tripNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(String(tripNote.prefix(60)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button {
                        tripNote = ""
                        showTripNote = true
                    } label: {
                        Label(
                            AppLocalization.text(english: "Log this trip", simplified: "记录这次行程", traditional: "記錄這次行程"),
                            systemImage: "checkmark.circle"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var departurePlan: DeparturePlan? {
        route.departurePlan(anchor: tripAnchor)
    }

    /// Scheduled first/last train times for the boarding line (official city-pack data).
    /// This is NOT a live countdown — the data sources have no real-time arrival feed.
    private var boardingServiceHours: (first: String, last: String)? {
        let firsts = boardingServiceWindows.compactMap(\.firstTime).filter { !$0.isEmpty }
        let lasts = boardingServiceWindows.compactMap(\.lastTime).filter { !$0.isEmpty }
        guard let first = firsts.min(), let last = lasts.max() else { return nil }
        return (first, last)
    }

    @ViewBuilder
    private var serviceHoursRow: some View {
        if let hours = boardingServiceHours {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.text(english: "Service hours", simplified: "运营时间", traditional: "營運時間"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(AppLocalization.text(
                        english: "First \(hours.first) · Last \(hours.last) (scheduled)",
                        simplified: "首班 \(hours.first) · 末班 \(hours.last)（时刻表）",
                        traditional: "首班 \(hours.first) · 末班 \(hours.last)（時刻表）"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func loadServiceHours(cityID: String) async {
        guard let stationName = route.boardingTransitSegment?.fromStationName else {
            boardingServiceWindows = []
            return
        }
        let windows = await container.officialStationData.serviceWindows(cityID: cityID, stationName: stationName)
        // .task(id:) cancelled this load because the rider switched route tabs — without this
        // guard a slow (e.g. network-bound) load for the OLD route lands after the new route's
        // cached one and shows the wrong service hours.
        guard !Task.isCancelled else { return }
        if let lineName = route.boardingTransitSegment?.lineName {
            let matched = windows.filter {
                $0.lineName == lineName || $0.lineName.contains(lineName) || lineName.contains($0.lineName)
            }
            boardingServiceWindows = matched.isEmpty ? windows : matched
        } else {
            boardingServiceWindows = windows
        }
    }

    private var stationsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.text(english: "Stations", simplified: "途经车站", traditional: "途經車站"))
                    .font(.headline)
                Text(AppLocalization.text(
                    english: "Tap a station for its exits, facilities and map.",
                    simplified: "点按车站查看出入口、设施和站内图。",
                    traditional: "點按車站查看出入口、設施和站內圖。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                RouteStationTimeline(stops: route.stationTimelineStops) { stop in
                    detailDestination = .station(stop)
                }
            }
        }
    }

    @ViewBuilder
    private var reminderSection: some View {
        if let departurePlan {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalization.text(english: "Leave-time reminder", simplified: "出发提醒", traditional: "出發提醒"))
                        .font(.headline)
                    Button {
                        // Capture the route ID with the plan: the auth prompt inside
                        // scheduleReminder awaits user input, and a tab switch during it
                        // would otherwise file this plan under the newly-shown route.
                        Task { await scheduleReminder(plan: departurePlan, routeID: route.id) }
                    } label: {
                        Label(
                            reminderScheduled
                                ? AppLocalization.text(english: "Reminder set", simplified: "提醒已设置", traditional: "提醒已設定")
                                : AppLocalization.text(
                                    english: "Remind me \(reminderLeadMinutes) min before departure",
                                    simplified: "出发前\(reminderLeadMinutes)分钟提醒我",
                                    traditional: "出發前\(reminderLeadMinutes)分鐘提醒我"
                                ),
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

    private func scheduleReminder(plan: DeparturePlan, routeID: UUID) async {
        guard plan.leaveByDate.addingTimeInterval(-Double(reminderLeadMinutes) * 60) > Date() else {
            showReminderTooLate = true
            return
        }
        guard await container.tripReminderService.requestAuthorization() else {
            showReminderDenied = true
            return
        }
        let scheduled = await container.tripReminderService.scheduleReminder(routeID: routeID, plan: plan, leadMinutes: reminderLeadMinutes)
        if scheduled {
            // Enforce a single active reminder: drop the one from a previously-reminded route
            // so scheduling on route A then route B can't leave two notifications pending.
            if let previous = scheduledReminderRouteID, previous != routeID {
                container.tripReminderService.cancelReminder(routeID: previous)
            }
            scheduledReminderRouteID = routeID
        }
        showReminderTooLate = !scheduled
    }

    func currentFeasibility() -> RouteFeasibility {
        container.routeFeasibilityService.feasibility(for: route)
    }

    private func currentConfidence(feasibility: RouteFeasibility) -> RouteConfidence {
        container.routeConfidenceService.confidence(
            for: route,
            feasibility: feasibility,
            preference: preference,
            alternatives: alternatives
        )
    }
}

/// Lightweight wrapper presented when a route's station timeline row is tapped. It resolves the
/// tapped stop to a full `Station` (loading city-pack data for that one station only) and shows
/// the standard `StationDetailView` — which lazy-loads exits/facilities/map via its own `.task`.
private struct RouteStationGuideSheet: View {
    let stop: RouteStationStop
    let cityID: String
    @Environment(DIContainer.self) private var container
    @State private var station: Station?
    @State private var didResolve = false

    var body: some View {
        Group {
            if let station {
                StationDetailView(station: station)
            } else if didResolve {
                StationDetailView(station: fallbackStation)
            } else {
                VStack(spacing: 14) {
                    Text(stop.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
            }
        }
        .task {
            // Only match when the stop carries a real coordinate — matching with a (0,0)
            // placeholder disambiguates same-named stations by distance to Null Island and
            // can pick the wrong one. A coordinate-less stop falls through to the
            // name-based fallback instead.
            if let coordinate = stop.coordinate {
                let place = TransitPlace(
                    name: stop.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    ),
                    source: .localStationData
                )
                station = await container.officialStationData.matchingStation(place: place, cityID: cityID)
            }
            didResolve = true
        }
    }

    private var fallbackStation: Station {
        stop.asStation(cityID: cityID)
    }
}
