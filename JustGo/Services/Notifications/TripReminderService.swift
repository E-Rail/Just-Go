import Foundation
import UserNotifications

/// The only notification layer in the app. Schedules a single "time to leave" local
/// notification for an explicit departure plan. Authorization is requested lazily
/// (never at launch) and past-dated reminders are never scheduled.
@MainActor
final class TripReminderService {
    private let center = UNUserNotificationCenter.current()

    private func identifier(for routeID: UUID) -> String { "trip-leave-\(routeID.uuidString)" }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Schedules the reminder `leadMinutes` before leave-by. Returns false if there is
    /// nothing to schedule (the fire time is already in the past).
    @discardableResult
    func scheduleReminder(routeID: UUID, plan: DeparturePlan, leadMinutes: Int) async -> Bool {
        cancelReminder(routeID: routeID)
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
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(for: routeID), content: content, trigger: trigger)
        try? await center.add(request)
        return true
    }

    func cancelReminder(routeID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: routeID)])
    }
}
