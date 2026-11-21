import Foundation

/// The spend chart's two moving parts: which window each range asks for, and
/// how a multi-day response folds onto one bar per day.
///
/// Both are pure arithmetic over server timestamps, so neither is verified
/// through a capture — the capture only ever holds one window, and the ranges
/// and the gaps between buckets are exactly where this can be quietly wrong.
///
/// Grouping is only meaningful against a fixed timezone, so the calendars here
/// are constructed explicitly rather than taken from the machine. Otherwise
/// these assertions would pass in Vienna and fail in Los Angeles.

@main
struct SpendTests {
    static var passed = 0
    static var failed = 0

    static func checkEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
        if actual == expected {
            passed += 1
            print("  ok    \(label)")
        } else {
            failed += 1
            print("  FAIL  \(label)  (expected \(expected), got \(actual))")
        }
    }

    static func check(_ label: String, _ condition: Bool) { checkEq(label, condition, true) }

    // MARK: - Fixtures

    static var vienna: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }()

    static var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-09-14 is a Monday. 1789344000 == 00:00 UTC that day.
    static let monday0000 = 1789344000

    static func at(_ calendar: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// Days between two instants, counted in the calendar rather than by
    /// dividing seconds — a DST change makes those disagree.
    static func dayCount(_ calendar: Calendar, from start: Date, to end: Date) -> Int {
        var n = 0
        var day = calendar.startOfDay(for: start)
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            n += 1
        }
        return n
    }

    // MARK: - Wire fixtures

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: json.data(using: .utf8)!)
        guard let payload = envelope.data?.biz_data else {
            throw DeepSeekError.malformed("no biz_data")
        }
        return payload
    }

    /// `buckets` is (time, requests, cacheHit, cacheMiss, output) per model.
    static func amount(start: Int, end: Int, bucket: Int = 86400,
                       series: [(String, [(Int, Int, Int, Int, Int)])]) throws -> AmountPayload {
        let models = series.map { model, buckets in
            let bs = buckets.map { t, req, hit, miss, out in
                """
                {"time": \(t), "usage": {"REQUEST": \(req),
                  "PROMPT_CACHE_HIT_TOKEN": \(hit), "PROMPT_CACHE_MISS_TOKEN": \(miss),
                  "RESPONSE_TOKEN": \(out)}}
                """
            }.joined(separator: ",")
            return #"{"api_key": null, "model": "\#(model)", "buckets": [\#(bs)]}"#
        }.joined(separator: ",")
        return try decode(AmountPayload.self, """
        {"code": 0, "msg": "", "data": {"biz_code": 0, "biz_msg": "", "biz_data": {
          "start": \(start), "end": \(end), "bucket": \(bucket), "series": [\(models)]}}}
        """)
    }

    /// `buckets` is (time, cost-as-a-string) per model, matching the dashboard,
    /// which reports money as text.
    static func cost(start: Int, end: Int, bucket: Int = 86400, currency: String = "USD",
                     series: [(String, [(Int, String)])]) throws -> CostPayload {
        let models = series.map { model, buckets in
            let bs = buckets.map { t, c in #"{"time": \#(t), "cost": "\#(c)"}"# }
                .joined(separator: ",")
            return #"{"api_key": null, "model": "\#(model)", "buckets": [\#(bs)]}"#
        }.joined(separator: ",")
        return try decode(CostPayload.self, """
        {"code": 0, "msg": "", "data": {"biz_code": 0, "biz_msg": "", "biz_data": {
          "start": \(start), "end": \(end), "bucket": \(bucket),
          "data": [{"currency": "\(currency)", "series": [\(models)]}]}}}
        """)
    }

    static func main() {
        ranges()
        serverWindows()
        grouping()
        costAcrossAPIKeys()
        persistence()

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - Which window each range asks for

    static func ranges() {
        print("\nRange windows (Europe/Vienna, so DST is in play):")

        // Late morning on Wednesday 2026-09-23, CEST.
        let now = at(vienna, 2026, 9, 23, 11, 30)

        let seven = SpendRange.sevenDays.window(now: now, calendar: vienna)
        checkEq("7 days starts six days back", seven.start, at(vienna, 2026, 9, 17))
        checkEq("7 days ends tomorrow", seven.end, at(vienna, 2026, 9, 24))
        checkEq("7 days spans 7 days", dayCount(vienna, from: seven.start, to: seven.end), 7)

        let thirty = SpendRange.thirtyDays.window(now: now, calendar: vienna)
        checkEq("30 days starts 29 days back", thirty.start, at(vienna, 2026, 8, 25))
        checkEq("30 days spans 30 days", dayCount(vienna, from: thirty.start, to: thirty.end), 30)

        // The month starts on the 1st, not 30 days back.
        let month = SpendRange.thisMonth.window(now: now, calendar: vienna)
        checkEq("this month starts on the 1st", month.start, at(vienna, 2026, 9, 1))
        checkEq("this month ends tomorrow", month.end, at(vienna, 2026, 9, 24))
        checkEq("the 23rd is 23 days in", dayCount(vienna, from: month.start, to: month.end), 23)

        print("\nRange edges:")
        // The ranges describe local days, and both ends land on local
        // midnight so the chart's bars line up with the days they name.
        // Whether the endpoint will *accept* those bounds is a separate
        // question, answered by `serverWindows()` below.
        for range in SpendRange.allCases {
            let w = range.window(now: now, calendar: vienna)
            check("\(range.label) start is midnight-aligned", w.start == vienna.startOfDay(for: w.start))
            check("\(range.label) end is midnight-aligned", w.end == vienna.startOfDay(for: w.end))
        }

        // The 1st of the month is a one-day window, not an empty one.
        let firstOfMonth = SpendRange.thisMonth.window(now: at(vienna, 2026, 9, 1, 9), calendar: vienna)
        checkEq("on the 1st, this month is today alone",
                dayCount(vienna, from: firstOfMonth.start, to: firstOfMonth.end), 1)

        // A 31-day month is genuinely 31 bars; the chart must not clip it to 30.
        let longMonth = SpendRange.thisMonth.window(now: at(vienna, 2026, 10, 31, 9), calendar: vienna)
        checkEq("a 31-day month yields 31 days",
                dayCount(vienna, from: longMonth.start, to: longMonth.end), 31)

        print("\nDaylight saving:")
        // Vienna leaves CEST on 2026-10-25, so a 7-day window across it contains
        // a 25-hour day. Counting days by dividing seconds would report 7 days
        // and change; the calendar reports 7 real ones.
        let dst = SpendRange.sevenDays.window(now: at(vienna, 2026, 10, 28, 9), calendar: vienna)
        checkEq("a window over the DST change still spans 7 days",
                dayCount(vienna, from: dst.start, to: dst.end), 7)
        checkEq("and it starts on 22 October", dst.start, at(vienna, 2026, 10, 22))
    }

    // MARK: - What the endpoint will accept

    /// The dashboard refuses a window unless both bounds are whole hours and
    /// the span is a whole number of 86400-second days. Local midnights
    /// satisfy that until a window straddles a DST change, where the day is
    /// 23 or 25 hours long and the naive window is a day plus or minus an
    /// hour — which is how the chart that worked all summer started failing
    /// with INVALID_PARAM in late October.
    static func serverWindows() {
        print("\nWindows as the endpoint will accept them:")

        func span(_ w: (start: Date, end: Date)) -> Double {
            w.end.timeIntervalSince(w.start)
        }
        func hourAligned(_ d: Date) -> Bool {
            d.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0
        }
        func wholeDays(_ w: (start: Date, end: Date)) -> Bool {
            span(w).truncatingRemainder(dividingBy: 86_400) == 0
        }

        // An ordinary week, wholly inside one offset, is untouched.
        let plainDesired = (start: at(vienna, 2026, 9, 17), end: at(vienna, 2026, 9, 24))
        let plain = DeepSeekClient.serverWindow(from: plainDesired.start, to: plainDesired.end)
        checkEq("an ordinary window keeps both midnights", plain.start, plainDesired.start)
        checkEq("and its end", plain.end, plainDesired.end)

        // Vienna leaves CEST on 2026-10-25. 22 to 29 October is seven local
        // days but 7 days and 1 hour of elapsed time.
        let dstEnd = at(vienna, 2026, 10, 29)
        let dst = DeepSeekClient.serverWindow(from: at(vienna, 2026, 10, 22), to: dstEnd)
        checkEq("a DST-crossing week still ends on local midnight", dst.end, dstEnd)
        checkEq("but spans exactly seven days", span(dst), 7 * 86_400)
        checkEq("with its start pulled to 01:00", dst.start, at(vienna, 2026, 10, 22, 1))
        check("and both bounds on a whole hour", hourAligned(dst.start) && hourAligned(dst.end))

        // The 25th itself is 25 hours long; this is the one-day refresh on
        // that day, which used to be refused outright.
        let longDay = DeepSeekClient.serverWindow(from: at(vienna, 2026, 10, 25),
                                                  to: at(vienna, 2026, 10, 26))
        checkEq("a 25-hour day becomes a 24-hour request", span(longDay), 86_400)
        checkEq("that still ends on the local midnight", longDay.end, at(vienna, 2026, 10, 26))

        // Spring is the same defect in the other direction.
        let shortDay = DeepSeekClient.serverWindow(from: at(vienna, 2026, 3, 29),
                                                   to: at(vienna, 2026, 3, 30))
        checkEq("a 23-hour day becomes a 24-hour request", span(shortDay), 86_400)

        print("\nEvery range on the far side of the DST change is acceptable:")
        for range in SpendRange.allCases {
            let desired = range.window(now: at(vienna, 2026, 10, 28, 9), calendar: vienna)
            let sent = DeepSeekClient.serverWindow(from: desired.start, to: desired.end)
            check("\(range.label): whole hours",
                  hourAligned(sent.start) && hourAligned(sent.end))
            check("\(range.label): whole days", wholeDays(sent))
            check("\(range.label): trimmed by at most an hour",
                  sent.start.timeIntervalSince(desired.start) >= 0
                  && sent.start.timeIntervalSince(desired.start) <= 3600)
        }
    }

    // MARK: - Folding buckets onto days

    static func grouping() {
        print("\nFolding a multi-day window onto one bar per day:")

        let end = monday0000 + 3 * 86400
        do {
            // Traffic on day 0 and day 2, nothing at all on day 1.
            let a = try amount(start: monday0000, end: end, series: [
                ("deepseek-flash", [
                    (monday0000,          10, 1_000_000, 0, 0),
                    (monday0000 + 2*86400, 5,  1_000_000, 0, 0),
                ]),
            ])
            // DeepSeek priced day 0 only.
            let c = try cost(start: monday0000, end: end, series: [
                ("deepseek-flash", [(monday0000, "0.42")]),
            ])
            let s = DeepSeekClient.spendSeries(amount: a, cost: c,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(end)),
                                               calendar: utc)

            checkEq("three bars for a three-day window", s.days.count, 3)
            checkEq("reported cost is used as-is", s.days[0].cost, Decimal(string: "0.42")!)
            checkEq("a reported day is not marked estimated", s.days[0].estimated, false)
            checkEq("day 0 requests", s.days[0].requests, 10)

            // The quiet day is present at zero, not omitted — otherwise every
            // later bar would sit one place too far left.
            checkEq("the idle day is a zero bar", s.days[1].cost, 0)
            checkEq("the idle day has no requests", s.days[1].requests, 0)
            checkEq("and it is still dated", s.days[1].day,
                    Date(timeIntervalSince1970: TimeInterval(monday0000 + 86400)))

            // Day 2 had no reported cost, so it falls back to the rate table.
            // 1M cache-hit tokens at deepseek-flash's off-peak rate of
            // $0.003/1M is exactly $0.003.
            checkEq("an unreported day is priced from the rate table",
                    s.days[2].cost, Decimal(string: "0.003")!)
            checkEq("and is marked estimated", s.days[2].estimated, true)

            checkEq("the total adds both kinds", s.total.amount, Decimal(string: "0.423")!)
            checkEq("and the total inherits the estimate flag", s.total.estimated, true)
            checkEq("the average is over every day, not just busy ones",
                    s.dailyAverage, Decimal(string: "0.141")!)
            checkEq("the busiest day is the reported one", s.busiest?.day, s.days[0].day)
        } catch {
            checkEq("three-day fold threw: \(error)", false, true)
        }

        print("\nSeveral models on one day:")
        do {
            // Two models, same day: the bar is their sum, and the request and
            // token counts add up too.
            let a = try amount(start: monday0000, end: monday0000 + 86400, series: [
                ("deepseek-flash", [(monday0000, 3, 1_000_000, 0, 0)]),
                ("deepseek-v4-pro", [(monday0000, 2, 0, 1_000_000, 0)]),
            ])
            let c = try cost(start: monday0000, end: monday0000 + 86400, series: [
                ("deepseek-flash", [(monday0000, "1.50")]),
                ("deepseek-v4-pro", [(monday0000, "2.50")]),
            ])
            let s = DeepSeekClient.spendSeries(amount: a, cost: c,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 86400)),
                                               calendar: utc)
            checkEq("one bar", s.days.count, 1)
            checkEq("costs sum across models", s.days[0].cost, Decimal(string: "4.00")!)
            checkEq("requests sum across models", s.days[0].requests, 5)
            checkEq("tokens sum across models", s.days[0].tokens, 2_000_000)
            checkEq("nothing was estimated", s.days[0].estimated, false)
        } catch {
            checkEq("multi-model fold threw: \(error)", false, true)
        }

        print("\nA partly-reported day is estimated, not silently short:")
        do {
            // One model priced, one not — the day must be flagged, since the
            // total is now a lower bound rather than DeepSeek's own figure.
            let a = try amount(start: monday0000, end: monday0000 + 86400, series: [
                ("deepseek-flash", [(monday0000, 1, 1_000_000, 0, 0)]),
                ("deepseek-v4-pro", [(monday0000, 1, 1_000_000, 0, 0)]),
            ])
            let c = try cost(start: monday0000, end: monday0000 + 86400, series: [
                ("deepseek-flash", [(monday0000, "1.00")]),
            ])
            let s = DeepSeekClient.spendSeries(amount: a, cost: c,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 86400)),
                                               calendar: utc)
            // $1.00 reported for flash, plus pro's 1M cache-hit at its
            // off-peak rate of $0.022/1M.
            checkEq("reported and estimated parts are added",
                    s.days[0].cost, Decimal(string: "1.022")!)
            checkEq("and the day is flagged", s.days[0].estimated, true)
        } catch {
            checkEq("partly-reported fold threw: \(error)", false, true)
        }

        print("\nThe two endpoints may disagree about which days they cover:")
        do {
            // The cost call can price a day the amount call returned no tokens
            // for. Dropping it would quietly understate the window.
            let a = try amount(start: monday0000, end: monday0000 + 2 * 86400, series: [
                ("deepseek-flash", [(monday0000, 1, 1_000_000, 0, 0)]),
            ])
            let c = try cost(start: monday0000, end: monday0000 + 2 * 86400, series: [
                ("deepseek-flash", [(monday0000, "1.00"), (monday0000 + 86400, "9.99")]),
            ])
            let s = DeepSeekClient.spendSeries(amount: a, cost: c,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 2 * 86400)),
                                               calendar: utc)
            checkEq("the priced-but-tokenless day is kept",
                    s.days[1].cost, Decimal(string: "9.99")!)
            checkEq("with no tokens attributed to it", s.days[1].tokens, 0)
            checkEq("the window total includes it", s.total.amount, Decimal(string: "10.99")!)
        } catch {
            checkEq("disagreeing-endpoints fold threw: \(error)", false, true)
        }

        print("\nCost is preferred in USD when the account holds several currencies:")
        do {
            let a = try amount(start: monday0000, end: monday0000 + 86400, series: [
                ("deepseek-flash", [(monday0000, 1, 1_000_000, 0, 0)]),
            ])
            // The EUR block is listed first, as it would be if the account were
            // billed in CNY and USD somewhere further down.
            let c = try decode(CostPayload.self, """
            {"code": 0, "msg": "", "data": {"biz_code": 0, "biz_msg": "", "biz_data": {
              "start": \(monday0000), "end": \(monday0000 + 86400), "bucket": 86400,
              "data": [
                {"currency": "CNY", "series": [{"api_key": null, "model": "deepseek-flash",
                  "buckets": [{"time": \(monday0000), "cost": "77"}]}]},
                {"currency": "USD", "series": [{"api_key": null, "model": "deepseek-flash",
                  "buckets": [{"time": \(monday0000), "cost": "1.25"}]}]}
              ]}}}
            """)
            let s = DeepSeekClient.spendSeries(amount: a, cost: c,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 86400)),
                                               calendar: utc)
            checkEq("the USD block wins", s.days[0].cost, Decimal(string: "1.25")!)
        } catch {
            checkEq("multi-currency fold threw: \(error)", false, true)
        }

        print("\nAn hourly reply still folds onto the right days:")
        // The server scales bucket width to the window, so a short range could
        // come back hourly. Grouping is by local day, so it lands correctly
        // either way rather than stacking 24 bars onto one date.
        do {
            let a = try amount(start: monday0000, end: monday0000 + 2 * 86400, bucket: 3600, series: [
                ("deepseek-flash", [
                    (monday0000,              1, 0, 0, 0),
                    (monday0000 + 3600,       1, 0, 0, 0),
                    (monday0000 + 86400 + 7200, 1, 0, 0, 0),
                ]),
            ])
            let s = DeepSeekClient.spendSeries(amount: a, cost: nil,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 2 * 86400)),
                                               calendar: utc)
            checkEq("two bars, not one per bucket", s.days.count, 2)
            checkEq("both hours landed on day 0", s.days[0].requests, 2)
            checkEq("the next day got its own", s.days[1].requests, 1)
            checkEq("bucket width is still reported", s.bucketSeconds, 3600)
        } catch {
            checkEq("hourly fold threw: \(error)", false, true)
        }

        print("\nA day's reported cost is counted once, not once per bucket:")
        // On the 1st of a month, "This month" is a one-day window, and a
        // one-day window comes back from the amount endpoint as hourly
        // buckets while the cost endpoint reports one figure for the day.
        // Applying that figure inside the bucket loop multiplied today's
        // spend by the number of hourly buckets.
        do {
            let a = try amount(start: monday0000, end: monday0000 + 86400, bucket: 3600, series: [
                ("deepseek-flash", [
                    (monday0000,             1, 1_000_000, 0, 0),
                    (monday0000 + 3600,      1, 1_000_000, 0, 0),
                    (monday0000 + 2 * 3600,  1, 1_000_000, 0, 0),
                ]),
            ])
            let c = try cost(start: monday0000, end: monday0000 + 86400, bucket: 3600, series: [
                ("deepseek-flash", [(monday0000, "1.00")]),
            ])
            let s = DeepSeekClient.spendSeries(amount: a, cost: c,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 86400)),
                                               calendar: utc)
            checkEq("the day costs what DeepSeek reported",
                    s.days[0].cost, Decimal(string: "1.00")!)
            checkEq("requests still add up across buckets", s.days[0].requests, 3)
            checkEq("and nothing was estimated", s.days[0].estimated, false)
        } catch {
            checkEq("hourly cost fold threw: \(error)", false, true)
        }

        print("\nA zero-token bucket is not an estimate:")
        do {
            // The dashboard emits buckets with no tokens at all. Pricing one
            // from the rate table yields zero and involved no guesswork, so it
            // must not put a "≥" on a window DeepSeek priced in full.
            let a = try amount(start: monday0000, end: monday0000 + 2 * 86400, series: [
                ("deepseek-flash", [
                    (monday0000,            1, 1_000_000, 0, 0),
                    (monday0000 + 86400,    0, 0, 0, 0),
                ]),
            ])
            let c = try cost(start: monday0000, end: monday0000 + 2 * 86400, series: [
                ("deepseek-flash", [(monday0000, "1.00")]),
            ])
            let s = DeepSeekClient.spendSeries(amount: a, cost: c,
                                               from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                                               to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 2 * 86400)),
                                               calendar: utc)
            checkEq("the empty bucket costs nothing", s.days[1].cost, 0)
            checkEq("and is not marked estimated", s.days[1].estimated, false)
            checkEq("so the window is not marked estimated", s.total.estimated, false)
            checkEq("with the total unchanged", s.total.amount, Decimal(string: "1.00")!)
        } catch {
            checkEq("zero-token fold threw: \(error)", false, true)
        }

        print("\nAn empty window is empty, not a missing one:")
        do {
            let s = DeepSeekClient.spendSeries(
                amount: try amount(start: monday0000, end: monday0000 + 3 * 86400, series: []),
                cost: nil,
                from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                to: Date(timeIntervalSince1970: TimeInterval(monday0000 + 3 * 86400)),
                calendar: utc)
            checkEq("still one bar per day", s.days.count, 3)
            checkEq("with nothing in it", s.isEmpty, true)
            checkEq("and no busiest day to report", s.busiest == nil, true)
            check("and a zero average rather than a divide by zero", s.dailyAverage == 0)
        } catch {
            checkEq("empty fold threw: \(error)", false, true)
        }
    }

    // MARK: - One model under several API keys

    /// The menu bar's fold is keyed by model, but the cost endpoint reports
    /// one series per (API key, model). Several keys that ran the same model
    /// land on the same entry, so their totals must add. Assigning instead
    /// keeps only the last key's figure: on a rotation day that showed
    /// $0.0022 beside a chart that correctly summed every key to $0.19.
    static func costAcrossAPIKeys() {
        print("\nOne model under several API keys:")
        do {
            let a = try decode(AmountPayload.self, """
            {"code": 0, "msg": "", "data": {"biz_code": 0, "biz_msg": "", "biz_data": {
              "start": \(monday0000), "end": \(monday0000 + 86400), "bucket": 3600, "series": [
                {"api_key": {"tracking_id": "key-a"}, "model": "deepseek-flash", "buckets": [
                  {"time": \(monday0000), "usage": {"REQUEST": 1, "PROMPT_CACHE_HIT_TOKEN": 1000}}]},
                {"api_key": {"tracking_id": "key-b"}, "model": "deepseek-flash", "buckets": [
                  {"time": \(monday0000), "usage": {"REQUEST": 2, "PROMPT_CACHE_MISS_TOKEN": 2000}}]}
              ]}}}
            """)
            let c = try decode(CostPayload.self, """
            {"code": 0, "msg": "", "data": {"biz_code": 0, "biz_msg": "", "biz_data": {
              "start": \(monday0000), "end": \(monday0000 + 86400), "bucket": 86400,
              "data": [{"currency": "USD", "series": [
                {"api_key": {"tracking_id": "key-a"}, "model": "deepseek-flash",
                 "buckets": [{"time": \(monday0000), "cost": "0.25"}]},
                {"api_key": {"tracking_id": "key-b"}, "model": "deepseek-flash",
                 "buckets": [{"time": \(monday0000), "cost": "0.75"}]}
              ]}]}}}
            """)
            let w = DeepSeekClient.merge(amount: a, cost: c)
            checkEq("one model row", w.models.count, 1)
            checkEq("requests add across keys", w.models.first?.requests ?? -1, 3)
            checkEq("cost adds across keys", w.cost?.amount, Decimal(string: "1.00")!)
            checkEq("every part was reported", w.cost?.estimated ?? true, false)
        } catch {
            checkEq("multi-key merge threw: \(error)", false, true)
        }
    }

    // MARK: - Remembering the selection

    static func persistence() {
        print("\nThe chosen range survives a relaunch:")
        let suite = UserDefaults(suiteName: "SpendTests")!
        suite.removePersistentDomain(forName: "SpendTests")

        checkEq("defaults to 7 days", SpendRange.load(from: suite), .sevenDays)
        SpendRange.thirtyDays.save(to: suite)
        checkEq("a saved range is read back", SpendRange.load(from: suite), .thirtyDays)
        SpendRange.thisMonth.save(to: suite)
        checkEq("and the next one replaces it", SpendRange.load(from: suite), .thisMonth)

        suite.set("something-else", forKey: SpendRange.defaultsKey)
        checkEq("an unrecognised value falls back to the default",
                SpendRange.load(from: suite), .sevenDays)

        suite.removePersistentDomain(forName: "SpendTests")
    }
}
