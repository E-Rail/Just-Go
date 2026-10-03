import Foundation
import CoreLocation

/// The trip in progress: what must keep going when no screen is showing it. The position on the
/// timeline, the fixes that correct it, every ride's "get ready" alert, and the saved copy a
/// relaunch resumes from.
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

    /// How far an alert's time must move before it is scheduled again: a walking fix re-anchors the
    /// trip every ten metres, and each one shifts every alert by a second or two.
    private static let alertRescheduleThreshold: TimeInterval = 30
    /// How long an arrived trip is kept before it ends itself, for a rider who never presses Done.
    private static let arrivedGrace: TimeInterval = 15 * 60
    /// The longest a trip is followed. Nothing on a bundled network takes this long, and a trip
    /// held open by fixes that never reach its end must not run the location hardware for a day.
    private static let longestTrip: TimeInterval = 6 * 60 * 60

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
                ActiveTripStore.clear()
                return nil
            }
        }
        return route
    }

    // MARK: - Starting and ending

    /// Begins following a route, or does nothing when it is already the one being followed. A
    /// saved trip resumes from its saved position.
    func start(_ route: Route) {
        guard self.route?.id != route.id else { return }
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
        locationService.beginContinuousUpdates()
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
        locationService.onFix = nil
        locationService.endContinuousUpdates()
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
        confirm(stepIndex: currentIndex - 1)
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
    /// platform to the last is still told at each stop they leave at.
    private func scheduleAlerts(force: Bool) {
        guard let timeline else { return }
        let wanted = alertsEnabled ? timeline.alerts(before: alertLead) : []
        let unchanged = wanted.count == scheduledAlerts.count && zip(wanted, scheduledAlerts).allSatisfy {
            $0.stepIndex == $1.stepIndex
                && abs($0.fireDate.timeIntervalSince($1.fireDate)) <= Self.alertRescheduleThreshold
        }
        guard force || !unchanged else { return }

        let dropped = Set(scheduledAlerts.map(\.stepIndex)).subtracting(wanted.map(\.stepIndex))
        dropped.forEach { reminders.cancelArrivalReminder(stationID: Self.alertKey($0)) }
        scheduledAlerts = wanted

        let steps = plan.steps
        alertTask?.cancel()
        guard !wanted.isEmpty else { return }
        alertTask = Task { [reminders] in
            guard await reminders.requestAuthorization() else { return }
            for alert in wanted {
                // Authorization can wait on a first-run prompt, and each `add` is its own await. A
                // newer schedule takes over from wherever this one got to: the keys are per step,
                // so it replaces what is here.
                guard !Task.isCancelled else { return }
                await reminders.scheduleArrivalReminder(
                    stationID: Self.alertKey(alert.stepIndex),
                    stationName: alert.stationName,
                    exitHint: steps.indices.contains(alert.stepIndex) ? steps[alert.stepIndex].exitHint : nil,
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
