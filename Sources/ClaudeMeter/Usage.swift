import Foundation

/// The plan's limits as `claude -p /usage` reports them.
struct Usage: Equatable {
    struct Window: Equatable {
        /// "5-hour limit", "Weekly · all models", "Weekly · Fable".
        let title: String
        /// Whole percents.
        let used: Int
        let resets: Date?
    }

    /// The 5-hour window; `/usage` calls it the current session.
    let session: Window?
    /// Every weekly window, all models first.
    let weeks: [Window]
    /// When they were read.
    let at: Date

    var windows: [Window] { (session.map { [$0] } ?? []) + weeks }

    /// 0…10: which tenth of the 5-hour limit is used — 100 % is its own step.
    /// The icon colour and the warnings both run on it.
    static func step(_ used: Int) -> Int { min(max(used, 0), 100) / 10 }

    // MARK: - Parsing

    /// The limits in `/usage`'s text, whose lines read
    ///
    ///     Current session: 14% used · resets Oct 8 at 3:19pm (Europe/Kiev)
    ///     Current week (all models): 51% used · resets Oct 8 at 12:59pm (Europe/Kiev)
    ///     Current week (Fable): 0% used · resets Oct 8 at 1pm (Europe/Kiev)
    ///
    /// The CLI writes the date in en-US, in its own time zone, with the year
    /// only when it isn't the current one. Older ICU puts ", " where "at" is.
    static func parse(_ text: String, now: Date) -> Usage? {
        var session: Window?
        var weeks: [Window] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "[\u{00A0}\u{2009}\u{202F}]", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard let groups = linePattern.groups(in: line), let used = groups[3].flatMap(Int.init) else { continue }
            let resets = groups[4].flatMap { date($0, zone: groups[5], now: now) }
            if let model = groups[2] {
                weeks.append(Window(title: "Weekly · \(model)", used: used, resets: resets))
            } else {
                session = Window(title: "5-hour limit", used: used, resets: resets)
            }
        }
        guard session != nil || !weeks.isEmpty else { return nil }
        // "all models" leads whatever order the CLI picks.
        weeks.sort { ($0.title.hasSuffix("all models") ? 0 : 1) < ($1.title.hasSuffix("all models") ? 0 : 1) }
        return Usage(session: session, weeks: weeks, at: now)
    }

    /// `/usage` cuts the reset time down to the minute, and the server's time
    /// wobbles around it by a second: one weekly reset reads "1pm" once and
    /// "12:59pm" the next. Within two minutes of the last reading, keep the
    /// later time — the cut only ever errs early.
    func steadied(after previous: Usage?) -> Usage {
        func pick(_ new: Window) -> Window {
            let old = previous?.windows.first { $0.title == new.title }
            guard let a = new.resets, let b = old?.resets, abs(a.timeIntervalSince(b)) <= 120 else { return new }
            return Window(title: new.title, used: new.used, resets: max(a, b))
        }
        return Usage(session: session.map(pick), weeks: weeks.map(pick), at: at)
    }

    private static let linePattern = try! NSRegularExpression(
        pattern: #"^Current (session|week \(([^)]+)\)): (\d+)% used(?: · resets (.+?)(?: \(([^)]+)\))?)?$"#)

    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(?:([A-Z][a-z]{2}) (\d{1,2})(?:, (\d{4}))?(?: at |, ))?(\d{1,2})(?::(\d{2}))? ?([ap]m)?$"#,
        options: .caseInsensitive)

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func date(_ text: String, zone: String?, now: Date) -> Date? {
        guard let groups = datePattern.groups(in: text), let hour = groups[4].flatMap(Int.init) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        if let month = groups[1].flatMap({ months.firstIndex(of: $0.lowercased()) }), let day = groups[2].flatMap(Int.init) {
            parts.month = month + 1
            parts.day = day
            if let year = groups[3].flatMap(Int.init) { parts.year = year }
        }
        switch groups[6]?.lowercased() {
        case "am": parts.hour = hour % 12
        case "pm": parts.hour = hour % 12 + 12
        default:   parts.hour = hour
        }
        parts.minute = groups[5].flatMap(Int.init) ?? 0
        guard let date = calendar.date(from: parts) else { return nil }
        // A bare time is today's, or tomorrow's once today's has gone by.
        if groups[1] == nil, date < now { return calendar.date(byAdding: .day, value: 1, to: date) }
        return date
    }
}

// MARK: - Formatting

enum Format {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    /// "15:19" today, "Thu 13:00" on another day.
    static func when(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? clock.string(from: date) : day.string(from: date)
    }

    /// "42 min", "3 h 05 min", "1 d 14 h"; whole minutes rounded up.
    static func span(to date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return String(format: "%d h %02d min", minutes / 60, minutes % 60) }
        return "\(minutes / (24 * 60)) d \(minutes % (24 * 60) / 60) h"
    }

    /// "42m", "4h 17m", "2d 5h": the menu's tight form.
    static func short(to date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return String(format: "%dh %02dm", minutes / 60, minutes % 60) }
        return "\(minutes / (24 * 60))d \(minutes % (24 * 60) / 60)h"
    }

    /// "just now", "4 min ago", "at 14:02".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "at \(when(date, now: now))"
    }
}

extension NSRegularExpression {
    /// The capture groups of a match, group 0 first; nil for groups that took
    /// no part.
    func groups(in text: String) -> [String?]? {
        guard let match = firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
