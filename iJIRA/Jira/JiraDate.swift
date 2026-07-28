import Foundation

/// Parser für Jira-Zeitstempel der Form `2026-06-23T11:13:10.123+0200`.
enum JiraDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    /// Zeitstempel mit `Z`/`+02:00`-Zone: so liefert die Agile-API die
    /// Sprint-Grenzen (`2026-07-22T14:58:54.982Z`), während die Issue-API
    /// `+0200` ohne Doppelpunkt schickt.
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return f
    }()

    static func parse(_ string: String) -> Date? {
        formatter.date(from: string)
    }

    /// Toleranter Parser für beide oben genannten Schreibweisen.
    static func parseLoose(_ string: String) -> Date? {
        parse(string) ?? isoFormatter.date(from: string)
    }
}
