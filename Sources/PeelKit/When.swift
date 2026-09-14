import Foundation

/// The time grammar behind @remind. Three layers, tried in order:
///   1. recurring:  "every day at 3pm", "every weekday 9am", "every monday 9:30"
///   2. relative:   "in 20 min", "in 2 hours", "in 3 days", bare "5m" / "2h" / "1d"
///   3. absolute:   NSDataDetector ("tomorrow 9am", "Sep 20, 2:30 PM")
/// Layers 1 and 2 are hand-rolled because NSDataDetector is unreliable for them.
public enum When {
    public enum Repeat: Equatable {
        case none
        case daily
        case weekdays
        case weekends
        case weekly(weekday: Int) // Calendar weekday: 1 = Sunday ... 7 = Saturday

        public var label: String? {
            switch self {
            case .none: return nil
            case .daily: return "every day"
            case .weekdays: return "weekdays"
            case .weekends: return "weekends"
            case .weekly(let day):
                let names = Calendar.current.weekdaySymbols
                return "every \(names[day - 1])"
            }
        }

        /// The weekdays this repeat fires on (Calendar numbering).
        public var firingWeekdays: [Int] {
            switch self {
            case .none, .daily: return []
            case .weekdays: return [2, 3, 4, 5, 6]
            case .weekends: return [1, 7]
            case .weekly(let day): return [day]
            }
        }
    }

    public struct Match: Equatable {
        public let date: Date
        public let repeats: Repeat
        public let range: NSRange
    }

    public static func detect(in line: String, now: Date = Date(),
                              calendar: Calendar = .current) -> Match? {
        recurring(in: line, now: now, calendar: calendar)
            ?? relative(in: line, now: now)
            ?? absolute(in: line, now: now)
    }

    // MARK: recurring

    private static let recurringRegex = try! NSRegularExpression(
        pattern: #"every\s+(day|weekdays?|weekends?|monday|mon|tuesday|tue|tues|wednesday|wed|thursday|thu|thurs|friday|fri|saturday|sat|sunday|sun)(?:\s+at)?\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?"#,
        options: [.caseInsensitive])

    private static func recurring(in line: String, now: Date, calendar: Calendar) -> Match? {
        let ns = line as NSString
        guard let m = recurringRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let what = ns.substring(with: m.range(at: 1)).lowercased()
        guard let (hour, minute) = clockTime(ns: ns, match: m, hourAt: 2, minuteAt: 3, ampmAt: 4)
        else { return nil }

        let repeats: Repeat
        switch what {
        case "day": repeats = .daily
        case "weekday", "weekdays": repeats = .weekdays
        case "weekend", "weekends": repeats = .weekends
        default:
            guard let weekday = weekdayNumber(for: what) else { return nil }
            repeats = .weekly(weekday: weekday)
        }

        guard let first = firstFire(repeats: repeats, hour: hour, minute: minute,
                                    now: now, calendar: calendar) else { return nil }
        return Match(date: first, repeats: repeats, range: m.range)
    }

    private static func weekdayNumber(for token: String) -> Int? {
        switch token.prefix(3) {
        case "sun": return 1
        case "mon": return 2
        case "tue": return 3
        case "wed": return 4
        case "thu": return 5
        case "fri": return 6
        case "sat": return 7
        default: return nil
        }
    }

    private static func firstFire(repeats: Repeat, hour: Int, minute: Int,
                                  now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        if case .daily = repeats {
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        }
        return repeats.firingWeekdays
            .compactMap { day -> Date? in
                var c = components
                c.weekday = day
                return calendar.nextDate(after: now, matching: c, matchingPolicy: .nextTime)
            }
            .min()
    }

    /// "3" with no am/pm means 3 PM: nobody sets reminders for 3 in the morning
    /// by accident. 8..12 without am/pm stay as written; 13+ is 24h time.
    private static func clockTime(ns: NSString, match: NSTextCheckingResult,
                                  hourAt: Int, minuteAt: Int, ampmAt: Int) -> (Int, Int)? {
        guard match.range(at: hourAt).location != NSNotFound,
              var hour = Int(ns.substring(with: match.range(at: hourAt))) else { return nil }
        let minute = match.range(at: minuteAt).location != NSNotFound
            ? Int(ns.substring(with: match.range(at: minuteAt))) ?? 0
            : 0
        let ampm = match.range(at: ampmAt).location != NSNotFound
            ? ns.substring(with: match.range(at: ampmAt)).lowercased()
            : ""
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if ampm == "pm", hour < 12 { hour += 12 }
        if ampm == "am", hour == 12 { hour = 0 }
        if ampm.isEmpty, (1...7).contains(hour) { hour += 12 }
        return (hour, minute)
    }

    // MARK: relative

    private static let relativeRegex = try! NSRegularExpression(
        pattern: #"(?:in\s+)?(\d+)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w)\b"#,
        options: [.caseInsensitive])

    private static func relative(in line: String, now: Date) -> Match? {
        let ns = line as NSString
        let matches = relativeRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            // bare "30 min" is fine; require the "in" prefix only to disambiguate
            // when the amount could read as a clock hour ("at 5 m..."? unlikely,
            // but "5m" without "in" is an accepted shorthand)
            guard let amount = Int(ns.substring(with: m.range(at: 1))), amount > 0 else { continue }
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            let seconds: TimeInterval
            switch unit.first {
            case "m": seconds = TimeInterval(amount) * 60
            case "h": seconds = TimeInterval(amount) * 3600
            case "d": seconds = TimeInterval(amount) * 86400
            case "w": seconds = TimeInterval(amount) * 604800
            default: continue
            }
            return Match(date: now.addingTimeInterval(seconds), repeats: .none, range: m.range)
        }
        return nil
    }

    // MARK: absolute (NSDataDetector fallback)

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func absolute(in line: String, now: Date) -> Match? {
        guard let detector else { return nil }
        let ns = line as NSString
        let matches = detector.matches(in: line, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if let date = m.date, date > now {
                return Match(date: date, repeats: .none, range: m.range)
            }
        }
        return nil
    }
}
