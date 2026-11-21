import Foundation

/// DeepSeek bills peak rates only during two windows on genuine Chinese
/// working days, and off-peak (exactly half price) at every other moment.
///
///   peak  <=>  Mon-Fri, Beijing  AND  UTC hour in [01:00,04:00) or [06:00,10:00)
///              AND  the Beijing date is not a public holiday
///
/// The schedule is published in Beijing time (09:00-12:00 and 14:00-18:00),
/// which is the same as the UTC windows above because Beijing is a whole
/// number of hours from UTC. Anchoring the *windows* in UTC and the *holiday
/// lookup* in Beijing keeps both unambiguous, and makes the local-time
/// display follow DST automatically rather than drifting twice a year.
///
/// The holiday table lives in `Holidays.swift`; this type knows only the
/// windows and the weekday rule.
///
/// Source: https://api-docs.deepseek.com/quick_start/pricing
enum PeakSchedule {

    /// UTC hours at which peak begins and ends. Half-open: [1,4) and [6,10).
    static let peakWindowHours: [Range<Int>] = [1..<4, 6..<10]

    /// How far ahead `nextTransition` scans for a state change, in days.
    ///
    /// The longest off-peak run the shipped table produces is the Spring
    /// Festival block when it follows a weekend: Friday 2026-02-13 10:00 UTC
    /// to Tuesday 2026-02-24 01:00 UTC, ten days and fifteen hours. Twelve
    /// days clears that with margin; a cap that merely matched National Day
    /// would blank the countdown for the festival.
    ///
    /// `Holidays.isStale` compares against the same horizon, because the
    /// countdown depends on the holiday table as far as this and not just on
    /// today. Sharing the constant is the point: widen the scan and the guard
    /// widens with it rather than silently under-warning.
    static let transitionScanDays = 12

    private static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    /// The schedule's own timezone. The windows are published in Beijing
    /// time, and the holiday table is keyed on Beijing dates, so weekday
    /// questions belong to this calendar too.
    private static var beijing: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    // MARK: - Peak state

    static func isPeak(_ date: Date) -> Bool {
        let utcCal = utc
        // Weekday and holiday both read Beijing, like every other day-level
        // rule here. At a peak window's hours the UTC and Beijing dates agree
        // (the windows are 09:00-12:00 and 14:00-18:00 Beijing), so this
        // cannot change the tier — it only keeps one calendar in charge.
        let weekday = beijing.component(.weekday, from: date)   // 1 = Sunday
        guard weekday >= 2, weekday <= 6 else { return false }  // Mon-Fri only
        guard peakWindowHours.contains(where: { $0.contains(utcCal.component(.hour, from: date)) })
        else { return false }
        return !Holidays.isHoliday(date)
    }

    enum State: String {
        case peak = "Peak"
        case offPeak = "Off-peak"

        var isPeak: Bool { self == .peak }
    }

    static func state(at date: Date) -> State { isPeak(date) ? .peak : .offPeak }

    // MARK: - Why off-peak

    /// The rule that made a moment off-peak, named.
    ///
    /// The three cases are exactly the three ways `isPeak` can fail, and they are
    /// read back in the order it tests them — so this is the tier's own decision
    /// explained, never a second opinion that could contradict what is on screen.
    enum OffPeakReason: Equatable {
        case weekend
        /// Carries the name, so the popover can say which holiday it was.
        case holiday(String)
        case outsidePeakHours
    }

    /// Why `date` is off-peak, or `nil` when it is peak and so has nothing to
    /// explain.
    ///
    /// A weekend answers as a weekend without consulting the holiday table. That
    /// is not just precedence: a make-up workday (调休) is a weekend day made into
    /// a working day, and DeepSeek bills it off-peak regardless, so the weekday
    /// settles the question on its own.
    static func offPeakReason(at date: Date) -> OffPeakReason? {
        guard !isPeak(date) else { return nil }
        // Beijing's weekday, not UTC's: for the eight hours a day when the two
        // dates differ, the UTC answer names a different day from the holiday
        // lookup below and contradicts the countdown beside it.
        let weekday = beijing.component(.weekday, from: date)   // 1 = Sunday
        if weekday == 1 || weekday == 7 { return .weekend }
        if let name = Holidays.holidayName(date) { return .holiday(name) }
        // Neither a weekend nor a holiday, and not peak either — so the hour is
        // the only thing left that can have decided it, and it is outside both
        // windows rather than inside one.
        return .outsidePeakHours
    }

    /// The next moment the peak/off-peak state changes.
    ///
    /// Scans minute by minute rather than deriving boundaries analytically:
    /// the state depends on the hour windows, the weekday, and a holiday
    /// table that each contribute edges, and a scan is far harder to get
    /// subtly wrong. The longest run it must cross is a holiday block that
    /// follows a weekend, not a weekend: 2026's Spring Festival scans 15,300
    /// minutes, from Fri 02-13 10:00 UTC to Tue 02-24 01:00. `transitionScanDays`
    /// is sized for that run. Callers cache the result.
    static func nextTransition(after date: Date) -> Date? {
        let cal = utc
        let current = isPeak(date)
        guard let start = cal.date(bySetting: .second, value: 0, of: date) else { return nil }
        let limit = transitionScanDays * 24 * 60
        for minute in 1...limit {
            guard let candidate = cal.date(byAdding: .minute, value: minute, to: start) else { return nil }
            if isPeak(candidate) != current { return candidate }
        }
        return nil
    }

    // MARK: - Display

    /// The peak windows that fall inside the local day containing `date`,
    /// clipped to that day and rendered as instants in `zone`.
    ///
    /// "Day" means the viewer's own: the popover labels these windows "today"
    /// beside a clock reading, so the answer must be about the day on the
    /// user's calendar. Anchoring them to the UTC day would show Friday's
    /// windows during Beijing's Saturday morning. Each local day is lit by
    /// whichever of the fixed Beijing windows overlap it, and DST shifts are
    /// handled by clipping rather than by assuming a 24-hour day.
    static func localPeakWindows(on date: Date, in zone: TimeZone = .current) -> [(start: Date, end: Date)] {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let dayStart = local.startOfDay(for: date)
        guard let dayEnd = local.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        // Windows last a few hours at most, so only the UTC days adjacent to
        // this local day can reach into it.
        let utcCal = utc
        let firstUTC = utcCal.date(byAdding: .day, value: -1,
                                   to: utcCal.startOfDay(for: dayStart)) ?? dayStart
        let lastUTC = utcCal.date(byAdding: .day, value: 1,
                                  to: utcCal.startOfDay(for: dayEnd)) ?? dayEnd

        var windows: [(start: Date, end: Date)] = []
        var utcDay = firstUTC
        while utcDay <= lastUTC {
            for hours in peakWindowHours {
                guard let s = utcCal.date(byAdding: .hour, value: hours.lowerBound, to: utcDay),
                      let e = utcCal.date(byAdding: .hour, value: hours.upperBound, to: utcDay),
                      // Weekends and holidays cancel the whole window; asking
                      // at its start answers for every minute of it.
                      isPeak(s) else { continue }
                let start = max(s, dayStart), end = min(e, dayEnd)
                if start < end { windows.append((start, end)) }
            }
            guard let next = utcCal.date(byAdding: .day, value: 1, to: utcDay) else { break }
            utcDay = next
        }
        return windows
    }

    /// Whether any part of the local day containing `date` is billed at peak.
    /// A day-level question, unlike `isPeak`, which answers for a moment.
    static func hasPeak(inLocalDayContaining date: Date, in zone: TimeZone = .current) -> Bool {
        !localPeakWindows(on: date, in: zone).isEmpty
    }

    /// e.g. "03:00-06:00, 08:00-12:00" in the given zone.
    static func localPeakWindowsText(on date: Date, in zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return localPeakWindows(on: date, in: zone)
            .map { "\(f.string(from: $0.start))-\(f.string(from: $0.end))" }
            .joined(separator: ", ")
    }
}
