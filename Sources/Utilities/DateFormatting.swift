import Foundation

/// Unified date formatting utilities for the app.
enum DateFormatting {
    /// Compact relative time: "now", "5m", "2h", "3d", or "Jan 5"
    static func compactRelativeTime(from date: Date) -> String {
        dashboardListTimestamp(from: date)
    }

    /// Shared dashboard list timestamp. Keep this compact so every list reads the same.
    static func dashboardListTimestamp(
        from date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 604800 { return "\(Int(interval / 86400))d" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "MMM d"
            : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
