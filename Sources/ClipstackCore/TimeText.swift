import Foundation

/// Compact copy-time labels for list rows: "Just now", "5m ago", "3h ago", "Yesterday", "Mon", "12 Mar".
public enum TimeText {
    public static func short(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 60 * 60 { return "\(Int(seconds / 60))m ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(seconds < 6 * 24 * 3600 ? "EEE" : "d MMM")
        return formatter.string(from: date)
    }
}
