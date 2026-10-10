import ActivityKit
import Foundation
import CoreLocation

/// The trip in progress: what must keep going when no screen is showing it. The position on the
/// timeline, the fixes that correct it, every ride's "get ready" alert, the Lock Screen's copy of
/// the step, and the saved copy a relaunch resumes from.
///
/// A trip runs from Navigate until the rider ends it or it arrives. Leaving the guidance screen
/// does not end it. Off-route re-planning stays with the screen, which hands the new route here.
@MainActor
@Observable
final class TripSession {
    @ObservationIgnored private let locationService: LocationService
    @ObservationIgnored private let reminders: TripReminderService
    @ObservationIgnored private let tripMemory: TripMemoryService

    /// The route being followed; a re-plan from where the rider is replaces it.
    private(set) var route: Route?
    /// The route as guidance began. A re-plan starts from "Current Location", and the trip history
    /// finds its planned row by the original two ends.
    private(set) var plannedRoute: Route?
    private(set) var plan = LiveTripPlan(steps: [], origin: "", destination: "")
    private(set) var position: TripPosition?
    /// The ride whose "get ready" moment has passed while the rider was on it. The screen raises
    /// its banner when this changes.
    private(set) var alightingSoonStep: Int?

    @ObservationIgnored private var timeline: TripTimeline?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var alertTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledAlerts: [TripAlert] = []
    @ObservationIgnored private var arrivedAt: Date?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var activity: Activity<TripActivityAttributes>?
    @ObservationIgnored private var shownActivityState: TripActivityAttributes.ContentState?
    @ObservationIgnored private var shownStaleDate: Date?
    @ObservationIgnored private var shownArrival: Date?
    /// Updates are awaited one after another: two sent at once can land in either order, and the
    /// Lock Screen would keep the older.
    @ObservationIgnored private var activityUpdates: Task<Void, Never>?

    /// How far an alert's time must move before it is scheduled again: a walking fix re-anchors the
    /// trip every ten metres, and each one shifts every alert by a second or two.
    private static let alertRescheduleThreshold: TimeInterval = 30
    /// How long an arrived trip is kept before it ends itself, for a rider who never presses Done.
    private static let arrivedGrace: TimeInterval = 15 * 60
    /// The longest a trip is followed. Nothing on a bundled network takes this long, and a trip
    /// held open by fixes that never reach its end must not run the location hardware for a day.
    private static let longestTrip: TimeInterval = 6 * 60 * 60
    /// How far a modelled time may drift before the Lock Screen is told. A walk re-anchors on
    /// every fix, and each one moves the trip's end and the next change by a second or two.
    private static let activityDriftThreshold: TimeInterval = 30
    /// How long past the next change the app should have reported the Lock Screen still counts as
    /// current. Beyond it the app has stopped updating, and the activity says so in place of a
    /// position.
    private static let activityStaleGrace: TimeInterval = 120

    init(locationService: LocationService, reminders: TripReminderService, tripMemory: TripMemoryService) {
        self.locationService = locationService
        self.reminders = reminders
        self.tripMemory = tripMemory
    }

    // MARK: - Reading

    var isActive: Bool { route != nil }

    var currentIndex: Int { position?.stepIndex ?? 0 }

    var currentStep: TripStep? {
        plan.steps.indices.contains(currentIndex) ? plan.steps[currentIndex] : nil
    }

    var canAdvance: Bool { currentIndex < plan.steps.count - 1 }
    var canGoBack: Bool { currentIndex > 0 }

    var progressText: String {
        AppLocalization.stepProgress(current: currentIndex + 1, total: plan.steps.count)
    }

    var progressFraction: Double {
        guard plan.steps.count > 1 else { return 1 }
        return Double(currentIndex) / Double(plan.steps.count - 1)
    }

    /// A trip left running when the app last closed, if it could still be under way. One the model
    /// has long since finished is dropped without asking: "Resume your trip?" the next morning is
    /// a question about nothing.
    func savedTrip(now: Date = Date()) -> Route? {
        guard let route = ActiveTripStore.load() else { return nil }
        if let anchor = ActiveTripStore.loadAnchor() {
            let timeline = TripTimeline(
                steps: LiveGoTripBuilder().timelineSteps(for: route),
                anchor: anchor,
                restoredAt: now
            )
            if now.timeIntervalSince(timeline.estimatedEnd) > Self.arrivedGrace {
                discardSavedTrip()
                return nil
            }
        }
        return route
    }

    /// Forgets the trip a relaunch would resume, and takes down what the app that saved it left
    /// with the system: its Lock Screen activity, and the alerts for rides it never reached. Both
    /// outlive the process, and neither has a trip behind it any more.
    func discardSavedTrip() {
        let saved = ActiveTripStore.load()
        ActiveTripStore.clear()
        guard !isActive else { return }
        if let saved {
            LiveGoTripBuilder().plan(for: saved).steps.indices.forEach {
                reminders.cancelArrivalReminder(stationID: Self.alertKey($0))
            }
        }
        endOrphanedActivities()
    }

    /// Stops still ahead on a ride, counted down as the trip moves: "2 stops left", and on the
    /// last hop the cue to get off. The step's own count until there is a position to read.
    func stopsLeftCount(for step: TripStep) -> String? {
        guard step.kind == .ride else { return nil }
        guard let remaining = position?.stopsRemaining else { return step.rideStopsRemainingText }
        if remaining == 1 {
            return AppLocalization.text(english: "Get off at the next stop", simplified: "下一站下车", traditional: "下一站下車")
        }
        return AppLocalization.stopsLeft(remaining)
    }

    /// The stop the train reaches next, while there is one before the rider's own.
    private var stopBeforeTheRiders: String? {
        guard let remaining = position?.stopsRemaining, remaining > 1 else { return nil }
        return position?.nextStopName
    }

    /// The count and the next stop in one line, as the navigator and the rider's panel print it.
    func stopsLeftText(for step: TripStep) -> String? {
        guard let count = stopsLeftCount(for: step) else { return nil }
        guard step.kind == .ride, let next = stopBeforeTheRiders else { return count }
        return AppLocalization.text(
            english: "\(count) · next \(next)",
            simplified: "\(count) · 下一站\(next)",
            traditional: "\(count) · 下一站\(next)"
        )
    }

    // MARK: - Starting and ending

    /// Begins following a route, or does nothing when it is already the one being followed. A
    /// saved trip resumes from its saved position.
    func start(_ route: Route) {
        // Also the route this trip was planned from: an off-route re-plan has since replaced it,
        // and opening guidance from the original's page must show the trip under way, not start
        // the old one over.
        guard route.id != self.route?.id, route.id != plannedRoute?.id else { return }
        stop()

        let now = Date()
        let builder = LiveGoTripBuilder()
        let steps = builder.timelineSteps(for: route)
        let saved = ActiveTripStore.load()?.id == route.id ? ActiveTripStore.loadAnchor() : nil
        let timeline = saved.map { TripTimeline(steps: steps, anchor: $0, restoredAt: now) }
            ?? TripTimeline(steps: steps, startedAt: now)

        self.route = route
        plannedRoute = route
        plan = builder.plan(for: route)
        self.timeline = timeline
        startedAt = now
        ActiveTripStore.save(route)
        ActiveTripStore.saveAnchor(timeline.anchor)

        locationService.onFix = { [weak self] in self?.observe($0) }
        locationService.beginTripUpdates()
        endOrphanedActivities()
        refresh(at: now)
        scheduleAlerts(force: true)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    /// Ends the trip and completes it in the rider's history, whichever way it ended. It asks the
    /// rider nothing: the packs and the route provider already carry those facts.
    func end() {
        if let planned = plannedRoute {
            tripMemory.markTripComplete(route: planned, cityID: planned.networkCityID ?? "")
        }
        stop()
        ActiveTripStore.clear()
    }

    /// Swaps in a freshly planned route (off-route recovery) and starts its steps from the first.
    func reroute(with newRoute: Route) {
        guard isActive else { return }
        // The old route's alerts go with it. Left to be replaced step by step, one already given
        // would count as given for whichever ride of the new route has its number.
        cancelAlerts()
        let now = Date()
        let builder = LiveGoTripBuilder()
        let timeline = TripTimeline(steps: builder.timelineSteps(for: newRoute), startedAt: now)
        route = newRoute
        plan = builder.plan(for: newRoute)
        self.timeline = timeline
        arrivedAt = nil
        alightingSoonStep = nil
        ActiveTripStore.save(newRoute)
        ActiveTripStore.saveAnchor(timeline.anchor)
        refresh(at: now)
        scheduleAlerts(force: true)
    }

    private func stop() {
        guard isActive else { return }
        ticker?.cancel()
        ticker = nil
        cancelAlerts()
        endActivity()
        locationService.onFix = nil
        locationService.endTripUpdates()
        route = nil
        plannedRoute = nil
        plan = LiveTripPlan(steps: [], origin: "", destination: "")
        timeline = nil
        position = nil
        alightingSoonStep = nil
        arrivedAt = nil
    }

    // MARK: - The rider's word

    func advance() {
        guard canAdvance else { return }
        confirm(stepIndex: currentIndex + 1)
    }

    func goBack() {
        guard canGoBack else { return }
        let now = Date()
        timeline?.goBack(to: currentIndex - 1, at: now)
        anchorMoved(at: now)
    }

    /// "I'm on the train": the one moment the clock cannot work out for itself.
    func confirmBoarded() {
        confirm(stepIndex: currentIndex)
    }

    private func confirm(stepIndex: Int) {
        let now = Date()
        timeline?.confirm(stepIndex: stepIndex, at: now)
        anchorMoved(at: now)
    }

    /// The alert toggle or its lead time changed.
    func alertPreferenceChanged() {
        scheduleAlerts(force: true)
    }

    // MARK: - Evidence and the clock

    private func observe(_ location: CLLocation) {
        // Only a fix in the map's frame can be measured against the route. With no correction known
        // the trip runs on the clock, which says so, where an uncorrected fix would say "located"
        // about a place half a kilometre away.
        guard var timeline, let corrected = locationService.correctedMapSpaceLocation(from: location) else { return }
        let fix = TripFix(
            point: TimelinePoint(latitude: corrected.coordinate.latitude, longitude: corrected.coordinate.longitude),
            accuracy: corrected.horizontalAccuracy,
            date: corrected.timestamp
        )
        let now = Date()
        guard timeline.observe(fix, now: now) else { return }
        self.timeline = timeline
        anchorMoved(at: now)
    }

    private func anchorMoved(at now: Date) {
        guard let timeline else { return }
        ActiveTripStore.saveAnchor(timeline.anchor)
        refresh(at: now)
        scheduleAlerts(force: false)
    }

    private func tick() {
        let now = Date()
        refresh(at: now)
        guard let timeline else { return }
        if timeline.hasArrived(at: now) {
            if arrivedAt == nil { arrivedAt = now }
        } else {
            arrivedAt = nil
        }
        let arrivedLongAgo = arrivedAt.map { now.timeIntervalSince($0) > Self.arrivedGrace } ?? false
        if arrivedLongAgo || now.timeIntervalSince(startedAt) > Self.longestTrip {
            end()
        }
    }

    private func refresh(at now: Date) {
        guard let timeline else { return }
        let next = timeline.position(at: now)
        // Assigned only on a change: every tick would otherwise redraw the screen for nothing.
        if next != position { position = next }

        let due = scheduledAlerts.first { $0.stepIndex == next.stepIndex && $0.fireDate <= now }?.stepIndex
        if due != alightingSoonStep { alightingSoonStep = due }

        // A train asks only which station; a walk needs the street.
        let kind = currentStep?.kind
        locationService.setStationLevelAccuracy(kind == .ride || kind == .transfer)
        updateActivity()
    }

    // MARK: - Lock Screen

    private func activityState(arrivingAt arrival: Date) -> TripActivityAttributes.ContentState? {
        guard let step = currentStep, let position else { return nil }
        // Up to the minute, so the clock never promises a minute the trip will not keep.
        let arrivalMinute = Date(
            timeIntervalSinceReferenceDate: (arrival.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60
        )
        return TripActivityAttributes.ContentState(
            symbolName: step.symbolName,
            // Arrival is not a leg and has no colour of its own; green is what the navigator uses.
            colorHex: step.colorHex ?? "#34C759",
            badge: step.kind == .ride ? step.lineName.map(LineBadge.shortLabel(for:)) : nil,
            title: step.title,
            detail: step.detail,
            stopsRemaining: position.stopsRemaining,
            stopsUnit: position.stopsRemaining.map {
                AppLocalization.text(english: $0 == 1 ? "stop" : "stops", simplified: "站", traditional: "站")
            },
            stopsText: stopsLeftCount(for: step),
            // A line of its own under the count, where the navigator runs the two together.
            nextStopText: step.kind == .ride ? stopBeforeTheRiders.map {
                AppLocalization.text(english: "Next stop: \($0)", simplified: "下一站 \($0)", traditional: "下一站 \($0)")
            } : nil,
            basisText: position.basis.label,
            isEstimated: position.basis == .estimated,
            arrivalText: step.kind == .arrive ? nil : ChinaClock.clockText(arrivalMinute),
            arrivalCaption: AppLocalization.text(english: "ETA", simplified: "预计到达", traditional: "預計抵達"),
            leg: leg(of: step, at: position),
            staleText: AppLocalization.text(
                english: "Open Just-Go to update",
                simplified: "打开 Just-Go 更新",
                traditional: "開啟 Just-Go 更新"
            )
        )
    }

    /// The step as the Lock Screen's strip draws it: its own track, and the lines either side.
    private func leg(of step: TripStep, at position: TripPosition) -> TripActivityAttributes.Leg? {
        guard let type = step.segmentType else { return nil }
        let rideBefore = plan.steps.prefix(position.stepIndex).last { $0.kind == .ride }
        let rideAfter = plan.steps.dropFirst(position.stepIndex + 1).first { $0.kind == .ride }
        let isRide = step.kind == .ride
        // A ride ends at a station on its own line. Any other leg ends at the station the next
        // ride leaves from, and with no ride left, at the destination.
        let endLine = isRide ? step : rideAfter
        return TripActivityAttributes.Leg(
            startColorHex: isRide ? step.colorHex : rideBefore?.colorHex,
            dash: type.dash(width: 1).map { Double($0) },
            parts: position.progress.parts,
            place: position.progress.place,
            marksStops: position.progress.countsStops,
            endName: endLine == nil ? plan.destination : step.toStationName ?? step.fromStationName,
            endColorHex: endLine?.colorHex,
            onwardBadge: rideAfter?.lineName.map(LineBadge.shortLabel(for:)),
            onwardColorHex: rideAfter?.colorHex
        )
    }

    /// The trip's end as the Lock Screen prints it, held while the estimate moves by less than the
    /// drift threshold: an estimate sitting on a minute boundary would otherwise flip the printed
    /// minute, and send an update, with every fix of a walk.
    private func settledArrival(for end: Date) -> Date {
        if let shown = shownArrival, abs(end.timeIntervalSince(shown)) <= Self.activityDriftThreshold {
            return shown
        }
        shownArrival = end
        return end
    }

    /// Puts the current step on the Lock Screen and in the Dynamic Island, when the rider allows
    /// Live Activities. Without them the trip runs the same, with the alerts as its only reach
    /// outside the app.
    ///
    /// Nothing the activity draws moves by itself, so it is told whenever what it draws changes,
    /// and it is given the moment past which silence from here means the app has stopped: the next
    /// change the clock would make, and a grace. Arrival has no next change and never goes stale.
    private func updateActivity() {
        guard let timeline, let position,
              let state = activityState(arrivingAt: settledArrival(for: timeline.estimatedEnd)) else { return }
        let staleDate = position.progress.changesAt?.addingTimeInterval(Self.activityStaleGrace)
        let staleDateMoved: Bool
        switch (staleDate, shownStaleDate) {
        case (nil, nil): staleDateMoved = false
        case let (new?, shown?): staleDateMoved = abs(new.timeIntervalSince(shown)) > Self.activityDriftThreshold
        default: staleDateMoved = true
        }
        if state == shownActivityState, !staleDateMoved { return }

        let content = ActivityContent(state: state, staleDate: staleDate)
        if let activity {
            shownActivityState = state
            shownStaleDate = staleDate
            let previous = activityUpdates
            let alert = Self.debugAlert
            activityUpdates = Task {
                await previous?.value
                await activity.update(content, alertConfiguration: alert)
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Refused when the app is not in the foreground or the system is at its limit, and asked
        // for again on the clock's next tick.
        activity = try? Activity.request(
            attributes: TripActivityAttributes(destination: plan.destination),
            content: content,
            pushType: nil
        )
        if activity != nil {
            shownActivityState = state
            shownStaleDate = staleDate
        }
    }

    #if DEBUG
    /// `JUST_GO_DEBUG_ACTIVITY_ALERT` makes every update an alert. An alert opens the expanded
    /// island on an iPhone and shows the Lock Screen's card as a banner on an iPad, and nothing
    /// else on a simulator reaches either.
    private static let debugAlert = ProcessInfo.processInfo.environment["JUST_GO_DEBUG_ACTIVITY_ALERT"] == nil
        ? nil
        : AlertConfiguration(title: "Just-Go", body: "Just-Go", sound: .default)
    #else
    private static let debugAlert: AlertConfiguration? = nil
    #endif

    private func endActivity() {
        shownActivityState = nil
        shownStaleDate = nil
        shownArrival = nil
        guard let activity else { return }
        self.activity = nil
        let previous = activityUpdates
        activityUpdates = Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Activities a previous process left behind. Ended before a new one is requested, and when a
    /// saved trip is dropped.
    private func endOrphanedActivities() {
        for orphan in Activity<TripActivityAttributes>.activities where orphan.id != activity?.id {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: - Alerts

    // The two settings the guidance screen and Settings write through `@AppStorage`, read here with
    // the same defaults. `bool(forKey:)` and `integer(forKey:)` after a presence check, because a
    // value from the launch arguments arrives as a string, which a cast to `Bool` refuses.
    private var alertsEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "arrivalAlertEnabled") == nil || defaults.bool(forKey: "arrivalAlertEnabled")
    }

    private var alertLead: TimeInterval {
        let defaults = UserDefaults.standard
        let minutes = defaults.object(forKey: "arrivalAlertLeadMinutes") == nil
            ? 2
            : defaults.integer(forKey: "arrivalAlertLeadMinutes")
        return TimeInterval(minutes * 60)
    }

    private static func alertKey(_ stepIndex: Int) -> String { "trip-step-\(stepIndex)" }

    /// Every ride's alert, set at once, so a rider whose phone stays in a pocket from the first
    /// platform to the last is still told at each stop they leave at. `TripTimeline.alertPlan`
    /// decides what changes; this carries it out.
    private func scheduleAlerts(force: Bool) {
        guard let timeline, let routeID = route?.id else { return }
        let now = Date()
        let alerts = timeline.alertPlan(
            holding: scheduledAlerts,
            before: alertsEnabled ? alertLead : nil,
            now: now
        )
        let unchanged = alerts.cancel.isEmpty && alerts.reached == nil
            && alerts.held.count == scheduledAlerts.count
            && zip(alerts.held, scheduledAlerts).allSatisfy {
                $0.stepIndex == $1.stepIndex
                    && abs($0.fireDate.timeIntervalSince($1.fireDate)) <= Self.alertRescheduleThreshold
            }
        guard force || !unchanged else { return }

        alerts.cancel.forEach { reminders.cancelArrivalReminder(stationID: Self.alertKey($0)) }
        scheduledAlerts = alerts.held

        let steps = plan.steps
        let exitHint: (TripAlert) -> String? = { alert in
            steps.indices.contains(alert.stepIndex) ? steps[alert.stepIndex].exitHint : nil
        }

        // What is to be given now goes by itself and is not cancelled by a newer schedule. The
        // plan already counts it as given, so one lost to a fix arriving a moment later would
        // never be made up.
        let dueNow = alerts.schedule.filter { $0.fireDate <= now }
        if !dueNow.isEmpty || alerts.reached != nil {
            Task { [weak self, reminders] in
                // Still this trip: authorization can wait on a first-run prompt, and the rider
                // may have ended the trip behind it.
                guard await reminders.requestAuthorization(), self?.route?.id == routeID else { return }
                for alert in dueNow {
                    await reminders.scheduleArrivalReminder(
                        stationID: Self.alertKey(alert.stepIndex),
                        stationName: alert.stationName,
                        exitHint: exitHint(alert),
                        fireDate: alert.fireDate
                    )
                }
                if let reached = alerts.reached {
                    await reminders.scheduleArrivalReminder(
                        stationID: Self.alertKey(reached.stepIndex),
                        stationName: reached.stationName,
                        exitHint: exitHint(reached),
                        fireDate: reached.fireDate,
                        reached: true
                    )
                }
            }
        }

        let later = alerts.schedule.filter { $0.fireDate > now }
        alertTask?.cancel()
        guard !later.isEmpty else { return }
        alertTask = Task { [reminders] in
            guard await reminders.requestAuthorization() else { return }
            for alert in later {
                // Authorization can wait on a first-run prompt, and each `add` is its own await. A
                // newer schedule takes over from wherever this one got to: the keys are per step,
                // so it replaces what is here.
                guard !Task.isCancelled else { return }
                await reminders.scheduleArrivalReminder(
                    stationID: Self.alertKey(alert.stepIndex),
                    stationName: alert.stationName,
                    exitHint: exitHint(alert),
                    fireDate: alert.fireDate
                )
            }
        }
    }

    private func cancelAlerts() {
        alertTask?.cancel()
        alertTask = nil
        // Every step, not only the ones last scheduled: a cancelled schedule may have got part-way.
        plan.steps.indices.forEach { reminders.cancelArrivalReminder(stationID: Self.alertKey($0)) }
        scheduledAlerts = []
    }
}


extension TripBasis {
    /// How a position is known, in a word. Nothing when the rider said so themselves: they know.
    var label: String? {
        switch self {
        case .located:
            return AppLocalization.text(english: "Located", simplified: "已定位", traditional: "已定位")
        case .estimated:
            return AppLocalization.text(english: "Estimated", simplified: "估算", traditional: "估算")
        case .confirmed:
            return nil
        }
    }
}
