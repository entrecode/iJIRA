import Foundation

/// Parser für Jira-Zeitstempel der Form `2026-06-23T11:13:10.123+0200`.
enum JiraDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    static func parse(_ string: String) -> Date? {
        formatter.date(from: string)
    }
}
