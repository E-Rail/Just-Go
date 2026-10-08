import Foundation
import UserNotifications

/// The app's only notification layer: a "time to leave" reminder for an explicit departure plan,
/// and a trip's "get off" alerts. Authorization is asked for when first needed, never at launch.
/// A leave reminder whose time has passed is not scheduled; a "get off" alert whose time has
/// passed is given at once.
@MainActor
final class TripReminderService {
    private let center = UNUserNotificationCenter.current()
    private let foregroundPresenter = ForegroundNotificationPresenter()

    init() {
        // Show local notifications as a banner while the app is foregrounded, so a "get off" alert
        // is visible with Live Go open.
        center.delegate = foregroundPresenter
    }

    /// One identifier for every leave reminder, so the system keeps a single one however many times
    /// a trip is re-planned.
    private let leaveIdentifier = "trip-leave"
    private func arrivalIdentifier(for stationID: String) -> String { "station-arrive-\(stationID)" }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Schedules the reminder `leadMinutes` before leave-by. Returns false when nothing was
    /// scheduled: the fire time is already past, or `add` refused the request.
    @discardableResult
    func scheduleReminder(plan: DeparturePlan, leadMinutes: Int) async -> Bool {
        // Cleared first, so a refused `add` leaves no reminder for an older plan behind it.
        center.removePendingNotificationRequests(withIdentifiers: [leaveIdentifier])
        let fireDate = plan.leaveByDate.addingTimeInterval(TimeInterval(-leadMinutes * 60))
        guard fireDate > Date() else { return false }

        let content = UNMutableNotificationContent()
        content.title = AppLocalization.text(english: "Time to leave", simplified: "出发时间到了", traditional: "出發時間到了")
        content.body = AppLocalization.text(
            english: "Leave by \(plan.leaveByText) to arrive around \(plan.arriveByText).",
            simplified: "请于 \(plan.leaveByText) 前出发，约 \(plan.arriveByText) 到达。",
            traditional: "請於 \(plan.leaveByText) 前出發，約 \(plan.arriveByText) 抵達。"
        )
        content.sound = .default

        var components = ChinaClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        components.timeZone = ChinaClock.calendar.timeZone
        // The calendar too, not only the zone: `UNCalendarNotificationTrigger` reads components
        // against `Calendar.current` when they name none, and a Gregorian year on a Buddhist or
        // Japanese calendar device is centuries away.
        components.calendar = ChinaClock.calendar
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: leaveIdentifier, content: content, trigger: trigger)
        // `add` throws (the 64-pending limit is reachable) and the caller shows the reminder as set
        // on this answer, so a swallowed throw would claim a reminder that does not exist.
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    /// Schedules a "get off" alert for `fireDate`, or gives it at once when that moment has come:
    /// the trip corrects its alerts as it learns where the train is, and a correction that finds
    /// the stop closer than the clock had it must not cost the rider the alert.
    ///
    /// Timed from segment durations; there is no live train-position feed, and the copy says so.
    /// `reached` is the one alert that is not an estimate: a fix has put the rider at the stop.
    /// Returns false when `add` refused the request.
    @discardableResult
    func scheduleArrivalReminder(
        stationID: String,
        stationName: String,
        exitHint: String?,
        fireDate: Date,
        reached: Bool = false
    ) async -> Bool {
        cancelArrivalReminder(stationID: stationID)
        // A time-interval trigger must be positive, and a second is the soonest it is reliable.
        let interval = max(1, fireDate.timeIntervalSinceNow)

        let content = UNMutableNotificationContent()
        let exit = exitHint.flatMap { $0.isEmpty ? nil : $0 }
        if reached {
            content.title = AppLocalization.text(english: "This is your stop", simplified: "到站了", traditional: "到站了")
            content.body = exit.map { exit in
                AppLocalization.text(
                    english: "You have reached \(stationName). Get off and head to \(exit).",
                    simplified: "已到达\(stationName)，请下车前往\(exit)。",
                    traditional: "已抵達\(stationName)，請下車前往\(exit)。"
                )
            } ?? AppLocalization.text(
                english: "You have reached \(stationName). Get off here.",
                simplified: "已到达\(stationName)，请下车。",
                traditional: "已抵達\(stationName)，請下車。"
            )
        } else {
            content.title = AppLocalization.text(english: "Get ready to get off", simplified: "准备下车", traditional: "準備下車")
            content.body = exit.map { exit in
                AppLocalization.text(
                    english: "Approaching \(stationName). Get off and head to \(exit). (estimated from route time)",
                    simplified: "即将到达\(stationName)，请下车前往\(exit)。（根据线路时间估算）",
                    traditional: "即將抵達\(stationName)，請下車前往\(exit)。（根據路線時間估算）"
                )
            } ?? AppLocalization.text(
                english: "Approaching \(stationName). Get ready to get off. (estimated from route time)",
                simplified: "即将到达\(stationName)，请准备下车。（根据线路时间估算）",
                traditional: "即將抵達\(stationName)，請準備下車。（根據路線時間估算）"
            )
        }
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: arrivalIdentifier(for: stationID), content: content, trigger: trigger)
        // Same reason as `scheduleReminder` above: the caller acts on this answer.
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func cancelArrivalReminder(stationID: String) {
        center.removePendingNotificationRequests(withIdentifiers: [arrivalIdentifier(for: stationID)])
    }
}

/// Presents local notifications as a banner while the app is foregrounded (iOS suppresses them
/// without a delegate). Not main-actor, to satisfy the nonisolated delegate requirement.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
