import Foundation

/// One holiday and the Beijing dates it covers.
///
/// The name is for the popover's off-peak explanation, which says *which*
/// holiday suppressed a peak window. Nothing about billing reads it.
struct HolidayPeriod {
    let name: String
    /// Inclusive Beijing-date range, "yyyy-MM-dd".
    let days: ClosedRange<String>
}

/// Chinese public holidays, as Beijing dates.
///
/// DeepSeek bills peak rates only on genuine Chinese working days, so a holiday
/// suppresses peak for its whole day. Weekends inside a holiday period are
/// off-peak anyway, so what actually matters is the weekdays covered.
///
/// **Two years, this one and the next.** The table rolls rather than growing:
/// add the new year's block when the State Council publishes (usually the
/// preceding November) and drop the oldest. Two, not one, because
/// `PeakSchedule.nextTransition` scans 12 days ahead, so the last days of
/// December already need January's data — the countdown becomes wrong with
/// nothing to indicate it.
///
/// Nothing historical depends on this: the only caller that classifies API data
/// is `DeepSeekClient.merge`, which is reached only from `fetchUsage`, which is
/// called only for *today*. The chart's `spendSeries` never consults it.
///
/// Deleting a range that is still in the future is silent — `isHoliday` just
/// returns false — so `isStale` exists to say when the table has run out.
enum Holidays {

    /// The shipped table, grouped by year so the annual edit is one commented
    /// block in, one out.
    static let holidayPeriods: [HolidayPeriod] = [
        // 2026 — 国办发明电〔2025〕7号
        HolidayPeriod(name: "New Year",             days: "2026-01-01"..."2026-01-03"),  // 元旦
        HolidayPeriod(name: "Spring Festival",      days: "2026-02-15"..."2026-02-23"),  // 春节
        HolidayPeriod(name: "Qingming Festival",    days: "2026-04-04"..."2026-04-06"),  // 清明节
        HolidayPeriod(name: "Labour Day",           days: "2026-05-01"..."2026-05-05"),  // 劳动节
        HolidayPeriod(name: "Dragon Boat Festival", days: "2026-06-19"..."2026-06-21"),  // 端午节
        HolidayPeriod(name: "Mid-Autumn Festival",  days: "2026-09-25"..."2026-09-27"),  // 中秋节
        HolidayPeriod(name: "National Day",         days: "2026-10-01"..."2026-10-07"),  // 国庆节
        // 2027 — not published yet. Add when the notice lands, usually Nov 2026.
    ]

    /// The same table as bare ranges, derived rather than kept alongside so the
    /// dates still have exactly one home: `coveredYears(in:)` and the tests take
    /// ranges, the popover needs the names.
    static var holidayRanges: [ClosedRange<String>] { holidayPeriods.map(\.days) }

    // MARK: - Coverage

    /// The years a set of ranges claims to cover, read off the bounds themselves.
    ///
    /// A gap *between* two ranges is an ordinary working period, not unknown
    /// days, so only the two ends of the covered span can be wrong — which is
    /// why the year, not the last listed day, is the unit here. Note the table's
    /// last listed day is National Day, `2026-10-07`, not year end: treating
    /// that as "coverage ends" would false-alarm from October 8th onward.
    ///
    /// Reading the year off the first four characters is safe because the format
    /// is fixed-width; it does not depend on the zero-padding discipline that a
    /// whole-string comparison would.
    static func coveredYears(in ranges: [ClosedRange<String>]) -> Set<Int> {
        Set(ranges.flatMap { [Int($0.lowerBound.prefix(4)), Int($0.upperBound.prefix(4))] }
                        .compactMap { $0 })
    }

    static let coveredYears: Set<Int> = coveredYears(in: holidayRanges)

    /// The last year the table knows about, for the UI copy.
    static let coveredThroughYear: Int? = coveredYears.max()

    /// True when the table cannot vouch for `date`, or for `lookaheadDays` after
    /// it.
    ///
    /// Two distinct failures, and only one is about today's tier. A bare
    /// `covered(date)` catches the tier being wrong; the horizon catches the
    /// *countdown* being wrong, because `nextTransition` reads up to 12 days
    /// ahead and so depends on the table as far as its scan reaches. The horizon
    /// test is not a superset — with coverage `{2026, 2028}`, 2027-12-28 is
    /// stale by day but its horizon is covered — so both are checked.
    ///
    /// A year-set test is also symmetric for free: a clock set backwards fails
    /// it too, where a "past the last day" comparison would stay silent while
    /// over-reporting peak all year.
    static func isStale(
        _ date: Date,
        lookaheadDays: Int = 0,
        in ranges: [ClosedRange<String>] = Holidays.holidayRanges
    ) -> Bool {
        let years = coveredYears(in: ranges)
        func covered(_ d: Date) -> Bool {
            guard let year = Int(beijingDay(of: d).prefix(4)) else { return false }
            return years.contains(year)
        }
        guard let horizon = beijingCalendar.date(byAdding: .day, value: lookaheadDays, to: date)
        else { return true }
        return !covered(date) || !covered(horizon)
    }

    // MARK: - Lookup

    private static let beijing = TimeZone(identifier: "Asia/Shanghai")!
    private static var beijingCalendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = beijing; return c
    }

    /// Beijing day -> the holiday covering it.
    ///
    /// One table rather than a set plus a lookup: the two answers differ only in
    /// whether the caller wants the name, and keeping them in step by
    /// construction is cheaper than remembering to.
    private static let holidayNamesByDay: [String: String] = {
        var names: [String: String] = [:]
        let cal = beijingCalendar
        let parse = DateFormatter()
        parse.calendar = cal
        parse.timeZone = beijing
        parse.dateFormat = "yyyy-MM-dd"
        parse.locale = Locale(identifier: "en_US_POSIX")

        for period in holidayPeriods {
            guard let start = parse.date(from: period.days.lowerBound),
                  let end = parse.date(from: period.days.upperBound) else { continue }
            var day = start
            while day <= end {
                names[parse.string(from: day)] = period.name
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return names
    }()

    /// One formatter for every lookup. `isHoliday` is on the transition
    /// scan's hot path — thousands of calls per scan — and building a
    /// DateFormatter each time was most of that cost. `DateFormatter` is
    /// thread-safe for formatting, and this one is never mutated after init.
    private static let beijingDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = beijingCalendar
        f.timeZone = beijing
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Beijing calendar date of a moment, as "yyyy-MM-dd".
    static func beijingDay(of date: Date) -> String {
        beijingDayFormatter.string(from: date)
    }

    static func isHoliday(_ date: Date) -> Bool {
        holidayName(date) != nil
    }

    /// The name of the holiday covering `date`, or `nil` on a working day.
    ///
    /// The date is Beijing's, like every other lookup in this table.
    static func holidayName(_ date: Date) -> String? {
        holidayNamesByDay[beijingDay(of: date)]
    }
}
