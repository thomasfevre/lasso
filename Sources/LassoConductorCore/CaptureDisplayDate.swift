import Foundation

/// Stable English display dates for Lasso's English-only interface.
public enum CaptureDisplayDate {
    public static func dayHeader(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(dateStyle: .full, timeStyle: .none, timeZone: timeZone).string(from: date)
    }

    public static func thumbnail(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(dateStyle: .medium, timeStyle: .short, timeZone: timeZone).string(from: date)
    }

    public static func detail(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(dateStyle: .medium, timeStyle: .short, timeZone: timeZone).string(from: date)
    }

    private static func formatter(dateStyle: DateFormatter.Style,
                                  timeStyle: DateFormatter.Style,
                                  timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
}
