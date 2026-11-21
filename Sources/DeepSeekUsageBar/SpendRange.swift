import Foundation

/// The windows the popover's spend chart can show.
///
/// Every one of them ends at *tomorrow's* midnight rather than today's, so
/// today is included and the last bar is the day you are in. The bounds are
/// local midnights because that is what the bars mean; the dashboard then
/// requires a whole number of days between them, which a window across a DST
/// change does not have — `DeepSeekClient.serverWindow` squares that when the
/// request is made, so the local-day arithmetic here stays honest.
enum SpendRange: String, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case thisMonth

    var id: String { rawValue }

    /// Short enough that three segments fit across a 340pt popover.
    var label: String {
        switch self {
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .thisMonth: return "This month"
        }
    }

    var help: String {
        switch self {
        case .sevenDays: return "The last 7 days, including today."
        case .thirtyDays: return "The last 30 days, including today."
        case .thisMonth: return "From the 1st of this month up to and including today."
        }
    }

    /// The local days to ask DeepSeek for, as midnight-aligned instants. The
    /// client turns these into bounds the endpoint will accept.
    ///
    /// `end` is exclusive — the midnight after the last day drawn — so today is
    /// in every range. A calendar month is anywhere from 1 to 31 days long,
    /// which is why the chart takes its length from the response rather than
    /// assuming one.
    func window(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        switch self {
        case .sevenDays:
            return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, tomorrow)
        case .thirtyDays:
            return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, tomorrow)
        case .thisMonth:
            // `dateInterval` rather than subtracting days: it is the calendar
            // that knows where this month began, and it gets February right
            // without a table.
            return (calendar.dateInterval(of: .month, for: now)?.start ?? today, tomorrow)
        }
    }

    // MARK: - Persistence

    static let defaultsKey = "spendRange"

    /// `defaults` is a parameter rather than a direct `.standard` reference so
    /// the stored value can be tested against a throwaway suite, as with
    /// `MenuBarItem.load`.
    static func load(from defaults: UserDefaults = .standard) -> SpendRange {
        guard let raw = defaults.string(forKey: defaultsKey),
              let parsed = SpendRange(rawValue: raw) else { return .sevenDays }
        return parsed
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
