import Foundation

/// Single source of truth for China-local (UTC+8) time math shared by the
/// trip-confidence features (service hours, last-train, rush-hour, departure planning).
///
/// Centralising the calendar and the midnight-wrap logic here prevents the three
/// time-aware features from each inventing a slightly different UTC+8 calendar or
/// wrap-around implementation.
enum ChinaClock {
    /// Gregorian calendar pinned to China Standard Time so first/last-train and
    /// rush-hour logic stay correct regardless of the device's own timezone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")
            ?? TimeZone(secondsFromGMT: 8 * 3600)
            ?? .current
        return calendar
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Parses a clock string into minutes-from-midnight (0..<1440).
    /// Tolerates "HH:mm", "H:mm", "HHmm", "Hmm", and surrounding whitespace; returns nil if unparseable.
    static func minutesOfDay(from text: String?) -> Int? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let hour: Int
        let minute: Int
        if raw.contains(":") {
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            hour = h
            minute = m
        } else if raw.count == 4, raw.allSatisfy(\.isNumber) {
            hour = Int(raw.prefix(2)) ?? -1
            minute = Int(raw.suffix(2)) ?? -1
        } else if raw.count == 3, raw.allSatisfy(\.isNumber) {
            hour = Int(raw.prefix(1)) ?? -1
            minute = Int(raw.suffix(2)) ?? -1
        } else {
            return nil
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// Minutes-from-midnight for a `Date` evaluated in China time.
    static func minutesOfDay(of date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// 1 = Sunday ... 7 = Saturday, in China time.
    static func weekday(of date: Date) -> Int {
        calendar.component(.weekday, from: date)
    }

    /// Monday–Friday in China time.
    static func isWeekday(_ date: Date) -> Bool {
        (2...6).contains(weekday(of: date))
    }

    /// Half-open membership test `[start, end)` in minutes-of-day. When `end <= start`
    /// the window is treated as crossing midnight (e.g. 23:00–00:30).
    static func isWithin(minute: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    /// "HH:mm" display string for a `Date` in China time.
    static func clockText(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    /// "H:mm" display string for a minutes-from-midnight value (wraps defensively).
    static func clockText(minutes: Int) -> String {
        let normalized = ((minutes % 1440) + 1440) % 1440
        return String(format: "%d:%02d", normalized / 60, normalized % 60)
    }
}
