import Foundation

/// Unified date formatting utilities for the app.
enum DateFormatting {
    /// Compact relative time: "now", "5m", "2h", "3d", or "Jan 5"
    static func compactRelativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    /// Compact dashboard timestamp with enough precision to explain ordering.
    static func dashboardListTimestamp(
        from date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
            return "Today, \(formatter.string(from: date))"
        }

        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d, h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy, h:mm a"
        }
        return formatter.string(from: date)
    }
}
