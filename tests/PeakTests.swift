import Foundation

/// Boundary tests for the peak/off-peak engine and the cost maths.
///
/// These are the pieces that must be exactly right: a wrong boundary silently
/// misprices every request near it, and a wrong holiday date misprices whole
/// days. Run via ./tests/run.sh

@main
struct PeakTests {
    static var passed = 0
    static var failed = 0

    /// Parse "yyyy-MM-dd HH:mm" as UTC, or nil if it does not parse.
    static func utcOpt(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    static func utc(_ s: String) -> Date { utcOpt(s)! }

    static func check(_ label: String, _ actual: Bool, _ expected: Bool) {
        if actual == expected {
            passed += 1
            print("  ok    \(label)")
        } else {
            failed += 1
            print("  FAIL  \(label)  (expected \(expected ? "peak" : "off-peak"), got \(actual ? "peak" : "off-peak"))")
        }
    }

    static func checkEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
        if actual == expected {
            passed += 1
            print("  ok    \(label)")
        } else {
            failed += 1
            print("  FAIL  \(label)  (expected \(expected), got \(actual))")
        }
    }

    static func main() {
        // 2026-09-14 is a Monday; 18th Friday, 19th Saturday, 20th Sunday.
        print("\nWindow boundaries (Monday 2026-09-14, UTC):")
        check("00:59 -> off-peak", PeakSchedule.isPeak(utc("2026-09-14 00:59")), false)
        check("01:00 -> peak",     PeakSchedule.isPeak(utc("2026-09-14 01:00")), true)
        check("03:59 -> peak",     PeakSchedule.isPeak(utc("2026-09-14 03:59")), true)
        check("04:00 -> off-peak", PeakSchedule.isPeak(utc("2026-09-14 04:00")), false)
        check("05:59 -> off-peak", PeakSchedule.isPeak(utc("2026-09-14 05:59")), false)
        check("06:00 -> peak",     PeakSchedule.isPeak(utc("2026-09-14 06:00")), true)
        check("09:59 -> peak",     PeakSchedule.isPeak(utc("2026-09-14 09:59")), true)
        check("10:00 -> off-peak", PeakSchedule.isPeak(utc("2026-09-14 10:00")), false)
        check("23:59 -> off-peak", PeakSchedule.isPeak(utc("2026-09-14 23:59")), false)

        print("\nWeekend is entirely off-peak:")
        check("Fri 09:30 -> peak",     PeakSchedule.isPeak(utc("2026-09-18 09:30")), true)
        check("Sat 09:30 -> off-peak", PeakSchedule.isPeak(utc("2026-09-19 09:30")), false)
        check("Sun 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-09-20 02:00")), false)
        check("Sat 01:30 -> off-peak", PeakSchedule.isPeak(utc("2026-09-19 01:30")), false)

        print("\nPublic holidays (weekdays that would otherwise be peak):")
        check("New Year Thu 01-01 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-01-01 02:00")), false)
        check("Spring Festival Mon 02-16 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-02-16 02:00")), false)
        check("Spring Festival end Mon 02-23 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-02-23 02:00")), false)
        check("Qingming Mon 04-06 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-04-06 02:00")), false)
        check("Labour Fri 05-01 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-05-01 02:00")), false)
        check("Dragon Boat Fri 06-19 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-06-19 02:00")), false)
        check("Mid-Autumn Fri 09-25 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-09-25 02:00")), false)
        check("National Day Thu 10-01 02:00 -> off-peak", PeakSchedule.isPeak(utc("2026-10-01 02:00")), false)

        print("\nDay after a holiday reverts to peak:")
        check("01-04 Sun -> off-peak (weekend)", PeakSchedule.isPeak(utc("2026-01-04 02:00")), false)
        check("02-24 Tue -> peak",               PeakSchedule.isPeak(utc("2026-02-24 02:00")), true)
        check("05-06 Wed -> peak",               PeakSchedule.isPeak(utc("2026-05-06 02:00")), true)
        check("10-08 Thu -> peak",               PeakSchedule.isPeak(utc("2026-10-08 02:00")), true)

        print("\nAdjusted make-up workdays are weekends, so off-peak either way:")
        check("Feb 14 Sat -> off-peak", PeakSchedule.isPeak(utc("2026-02-14 02:00")), false)
        check("Feb 28 Sat -> off-peak", PeakSchedule.isPeak(utc("2026-02-28 02:00")), false)
        check("May 09 Sat -> off-peak", PeakSchedule.isPeak(utc("2026-05-09 02:00")), false)
        check("Sep 20 Sun -> off-peak", PeakSchedule.isPeak(utc("2026-09-20 02:00")), false)
        check("Oct 10 Sat -> off-peak", PeakSchedule.isPeak(utc("2026-10-10 02:00")), false)

        print("\nWhy a moment is off-peak:")
        // The three answers are the three ways the peak rule fails, and the
        // popover shows whichever one comes back. A wrong reason is not a
        // mispricing — the tier is unchanged — but it is a lie on screen, and
        // the weekend-before-holiday precedence is the part worth pinning.
        checkEq("Mon 12:00 is a working day, not a weekend or a holiday",
                PeakSchedule.offPeakReason(at: utc("2026-09-14 12:00")), .outsidePeakHours)
        checkEq("Mon 00:59 is the same working day, an hour earlier",
                PeakSchedule.offPeakReason(at: utc("2026-09-14 00:59")), .outsidePeakHours)
        checkEq("Sat 12:00 is the weekend",
                PeakSchedule.offPeakReason(at: utc("2026-09-19 12:00")), .weekend)
        // Sat 02:00 is inside a peak window's hours, so the weekday is the only
        // thing making it off-peak and the reason must say so.
        checkEq("Sat 02:00 is the weekend, not the hour",
                PeakSchedule.offPeakReason(at: utc("2026-09-19 02:00")), .weekend)
        checkEq("a make-up workday is just a Saturday to this",
                PeakSchedule.offPeakReason(at: utc("2026-02-14 02:00")), .weekend)

        // 09-25 is the Friday of Mid-Autumn and 10-05 the Monday of National Day;
        // both are weekdays inside a peak window that the holiday cancelled, which
        // is the case the reason exists for.
        checkEq("a holiday names itself",
                PeakSchedule.offPeakReason(at: utc("2026-09-25 02:00")),
                .holiday("Mid-Autumn Festival"))
        checkEq("so does a holiday outside the windows",
                PeakSchedule.offPeakReason(at: utc("2026-10-05 12:00")),
                .holiday("National Day"))
        checkEq("a holiday on a Saturday still reads as the weekend",
                PeakSchedule.offPeakReason(at: utc("2026-09-26 02:00")), .weekend)
        checkEq("the Monday after Mid-Autumn is an ordinary working day",
                PeakSchedule.offPeakReason(at: utc("2026-09-28 02:00")), nil)
        // The weekday is Beijing's, like the holiday beside it. Friday 23:00
        // UTC is Saturday in Beijing, and Sunday 23:00 UTC is Monday morning
        // there; reading UTC would swap both answers.
        checkEq("a Beijing weekend read during a UTC Friday",
                PeakSchedule.offPeakReason(at: utc("2026-09-18 23:00")), .weekend)
        checkEq("a Beijing working morning read during a UTC Sunday",
                PeakSchedule.offPeakReason(at: utc("2026-09-13 23:00")), .outsidePeakHours)

        print("\nPeak has no reason to give:")
        let noReason: PeakSchedule.OffPeakReason? = nil
        checkEq("Mon 02:00 is peak", PeakSchedule.offPeakReason(at: utc("2026-09-14 02:00")), noReason)
        checkEq("and the reason agrees with the tier it explains",
                PeakSchedule.offPeakReason(at: utc("2026-09-19 02:00")) == nil,
                PeakSchedule.isPeak(utc("2026-09-19 02:00")))

        print("\nWhether a day has any peak at all:")
        // The popover prints the windows or "none", so a day that is entirely
        // off-peak must not be shown the clock's two windows. Judged in a
        // given zone; UTC here, so these read the UTC day.
        let utcZone = TimeZone(identifier: "UTC")!
        func hasPeak(_ date: Date) -> Bool {
            PeakSchedule.hasPeak(inLocalDayContaining: date, in: utcZone)
        }
        check("Mon 09-14 has peak", hasPeak(utc("2026-09-14 12:00")), true)
        check("Sat 09-19 has none", hasPeak(utc("2026-09-19 12:00")), false)
        check("Sun 09-20 has none", hasPeak(utc("2026-09-20 12:00")), false)
        check("Fri 09-25 has none (Mid-Autumn)", hasPeak(utc("2026-09-25 12:00")), false)
        check("Mon 10-05 has none (National Day)", hasPeak(utc("2026-10-05 12:00")), false)
        check("Thu 10-08 has peak again", hasPeak(utc("2026-10-08 12:00")), true)
        check("asked late in the day, still about that day",
              hasPeak(utc("2026-09-24 23:00")), true)
        checkEq("and the reason now agrees with the day",
                hasPeak(utc("2026-09-27 12:00")),
                PeakSchedule.state(at: utc("2026-09-27 12:00")) == .peak)

        print("\n\"Today\" is the viewer's local day:")
        let beijing = TimeZone(identifier: "Asia/Shanghai")!
        // Saturday 07:00 Beijing is still Friday 23:00 UTC. The viewer is in
        // Saturday, and Saturday has no peak — the UTC-day answer said Friday
        // and printed Friday's windows.
        check("Beijing Sat 07:00 has no peak today",
              PeakSchedule.hasPeak(inLocalDayContaining: utc("2026-09-18 23:00"), in: beijing),
              false)
        // Monday 07:00 Beijing is Sunday 23:00 UTC; Monday's windows are ahead.
        check("Beijing Mon 07:00 has peak today",
              PeakSchedule.hasPeak(inLocalDayContaining: utc("2026-09-13 23:00"), in: beijing),
              true)
        checkEq("and the windows shown are Monday's",
                PeakSchedule.localPeakWindowsText(on: utc("2026-09-13 23:00"), in: beijing),
                "09:00-12:00, 14:00-18:00")

        // The invariant the popover rests on: it must never print "Peak rates"
        // above "Peak today: none". Scanned hourly over a fortnight spanning a
        // weekend and the Mid-Autumn block, which is where the two could come
        // apart — the moment-level answer and the day-level one are computed
        // from the same rules but at different instants.
        var peakWithoutDayPeak = 0
        var probe = utc("2026-09-18 00:00")
        for _ in 0..<(14 * 24) {
            if PeakSchedule.isPeak(probe), !hasPeak(probe) { peakWithoutDayPeak += 1 }
            probe = probe.addingTimeInterval(3600)
        }
        checkEq("peak always implies the day has peak", peakWithoutDayPeak, 0)

        print("\nEvery holiday range's stated ends are holidays:")
        // Iterates the table rather than repeating its dates, so a bound that is
        // mistyped or dropped fails here without anyone having to remember to
        // extend a list. This matters more than it looks: the builder skips a
        // range it cannot parse, so one bad character removes a whole holiday in
        // silence.
        for range in Holidays.holidayRanges {
            for bound in [range.lowerBound, range.upperBound] {
                if let day = utcOpt("\(bound) 02:00") {
                    checkEq("\(bound) is a holiday", Holidays.isHoliday(day), true)
                } else {
                    checkEq("\(bound) parses as yyyy-MM-dd", false, true)
                }
            }
        }

        print("\nThe holiday date is Beijing's, not the viewer's:")
        // 18:00 UTC is 20:00 in Vienna but already 02:00 the next day in Beijing,
        // so these two instants have Vienna and Beijing on different dates. Both
        // must follow Beijing: the first is a holiday there while Vienna is still
        // on the previous working day, and the second is a working day there
        // while Vienna is still on the holiday's last day. Judging the holiday by
        // the local date would answer both backwards. Verified 2026-09-25 that no
        // peak window ever falls at an instant where the two dates differ — for
        // Vienna, or for any zone east of UTC-1 — so this cannot misprice a tier;
        // it is pinned because it is the semantics the whole table rests on.
        checkEq("Sep 24 18:00 UTC is a holiday (Beijing already Sep 25)",
                Holidays.isHoliday(utc("2026-09-24 18:00")), true)
        checkEq("Sep 27 18:00 UTC is not (Beijing already Sep 28)",
                Holidays.isHoliday(utc("2026-09-27 18:00")), false)

        print("\nHoliday table coverage:")
        // Read off the bounds, not the calendar: a gap *between* two ranges is a
        // working period rather than unknown days, so only the years the table
        // actually names can be wrong.
        checkEq("years come off the bounds",
                Holidays.coveredYears(in: ["2027-01-01"..."2027-01-03",
                                           "2028-10-01"..."2028-10-07"]),
                Set([2027, 2028]))

        let only2026: [ClosedRange<String>] = ["2026-01-01"..."2026-01-03",
                                              "2026-10-01"..."2026-10-07"]
        check("a covered day is not stale",
              Holidays.isStale(utc("2026-12-28 02:00"), in: only2026), false)
        // The countdown reads 8 days ahead, so the last week of a covered year is
        // already consulting a year the table knows nothing about.
        check("but the scan horizon is",
              Holidays.isStale(utc("2026-12-28 02:00"), lookaheadDays: 8, in: only2026), true)
        check("an uncovered year is stale",
              Holidays.isStale(utc("2027-01-04 02:00"), in: only2026), true)

        print("\nA stale table does not change the tier:")
        // 2035-06-04 is a Monday, and 02:00 UTC is inside [01:00,04:00), so this
        // is peak on the weekday and the window alone. Reporting off-peak for a
        // year the table cannot vouch for would understate cost, which is the
        // error worth avoiding.
        check("a far-future weekday still reports peak",
              PeakSchedule.isPeak(utc("2035-06-04 02:00")), true)

        print("\nShipped table (edit when the next year's notice lands):")
        checkEq("covers exactly the years shipped", Holidays.coveredYears, Set([2026]))
        checkEq("coverage is reported for the copy", Holidays.coveredThroughYear ?? -1, 2026)

        print("\nLocal rendering follows DST (Europe/Vienna):")
        let vienna = TimeZone(identifier: "Europe/Vienna")!
        checkEq("summer (CEST) peak windows",
                PeakSchedule.localPeakWindowsText(on: utc("2026-09-14 12:00"), in: vienna),
                "03:00-06:00, 08:00-12:00")
        checkEq("winter (CET) peak windows",
                PeakSchedule.localPeakWindowsText(on: utc("2026-01-19 12:00"), in: vienna),
                "02:00-05:00, 07:00-11:00")

        print("\nNext transition:")
        // 01:30 UTC Monday is inside [01:00,04:00 -> 04:00.
        checkEq("from Mon 01:30 -> 04:00",
                PeakSchedule.nextTransition(after: utc("2026-09-14 01:30"))!, utc("2026-09-14 04:00"))
        // 09:30 UTC Monday -> 10:00, then off-peak until Tuesday 01:00.
        checkEq("from Mon 09:30 -> 10:00",
                PeakSchedule.nextTransition(after: utc("2026-09-14 09:30"))!, utc("2026-09-14 10:00"))
        checkEq("from Mon 10:00 -> Tue 01:00",
                PeakSchedule.nextTransition(after: utc("2026-09-14 10:00"))!, utc("2026-09-15 01:00"))
        // Friday after 10:00 stays off-peak until Monday 01:00.
        checkEq("from Fri 10:00 -> Mon 01:00",
                PeakSchedule.nextTransition(after: utc("2026-09-18 10:00"))!, utc("2026-09-21 01:00"))
        // Spring Festival follows a weekend, so the off-peak run is 10 days
        // 15 hours — longer than National Day and past the old 8-day cap,
        // which returned nil and blanked the countdown for days.
        checkEq("from Fri 02-13 12:00 -> Tue 02-24 01:00",
                PeakSchedule.nextTransition(after: utc("2026-02-13 12:00"))!,
                utc("2026-02-24 01:00"))

        print("\nPricing:")
        let flash = Pricing.rates(for: "deepseek-flash")!
        let pro = Pricing.rates(for: "deepseek-v4-pro")!
        // 1M cache-miss tokens: flash peak $0.30, off-peak half.
        checkEq("flash 1M miss peak",
                Pricing.usd(Pricing.cost(cacheHitTokens: 0, cacheMissTokens: 1_000_000, outputTokens: 0, rates: flash, isPeak: true)), "$0.30")
        checkEq("flash 1M miss off-peak",
                Pricing.usd(Pricing.cost(cacheHitTokens: 0, cacheMissTokens: 1_000_000, outputTokens: 0, rates: flash, isPeak: false)), "$0.15")
        checkEq("pro 1M output peak",
                Pricing.usd(Pricing.cost(cacheHitTokens: 0, cacheMissTokens: 0, outputTokens: 1_000_000, rates: pro, isPeak: true)), "$3.96")
        // The alias the Claude Code profile actually sends must resolve.
        checkEq("undocumented alias resolves to flash",
                Pricing.rates(for: "deepseek-v4-flash")!.cacheMiss, flash.cacheMiss)
        checkEq("unknown model has no rates", Pricing.rates(for: "gpt-4") == nil, true)

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
