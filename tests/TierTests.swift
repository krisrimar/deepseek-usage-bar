import Foundation

/// Peak/off-peak attribution from hourly buckets.
///
/// This is the feature the whole design turns on: the dashboard returns
/// `bucket=3600` when asked for a single day, and each bucket's timestamp says
/// which rate tier it was billed at. If this classification is wrong the app
/// confidently reports the wrong number, so it is tested directly rather than
/// only through a capture.
///
/// Timestamps are UTC and the schedule is UTC-anchored, so these results do
/// not depend on the machine's timezone.

@main
struct TierTests {
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

    static func check(_ label: String, _ condition: Bool) {
        checkEq(label, condition, true)
    }

    /// 2026-09-14 is a Monday. 1789344000 == 00:00 UTC that day.
    static let monday0000 = 1789344000

    static func payload(bucket: Int, buckets: [(Int, Int, Int, Int)]) -> Data {
        let series = buckets.map { (time, hit, miss, out) in
            """
            {"api_key": null, "model": "deepseek-flash", "buckets": [
              {"time": \(time), "usage": {
                "RESPONSE_TOKEN": \(out), "REQUEST": 1,
                "PROMPT_CACHE_HIT_TOKEN": \(hit), "PROMPT_CACHE_MISS_TOKEN": \(miss)}}]}
            """
        }.joined(separator: ",")
        let json = """
        {"code": 0, "msg": "", "data": {"biz_code": 0, "biz_msg": "", "biz_data": {
          "start": \(monday0000), "end": \(monday0000 + 86400), "bucket": \(bucket),
          "series": [\(series)]}}}
        """
        return json.data(using: .utf8)!
    }

    static func decode(_ data: Data) throws -> UsageWindow {
        let envelope = try JSONDecoder().decode(Envelope<AmountPayload>.self, from: data)
        guard let amount = envelope.data?.biz_data else {
            throw DeepSeekError.malformed("no biz_data")
        }
        return DeepSeekClient.merge(amount: amount, cost: nil)
    }

    static func main() {
        print("\nHourly buckets split by rate tier (Monday 2026-09-14):")

        // 02:00 UTC is inside the peak window [01:00,04:00); 12:00 UTC is not.
        let peakStart = monday0000 + 2 * 3600
        let offPeakStart = monday0000 + 12 * 3600

        do {
            let window = try decode(payload(bucket: 3600, buckets: [
                (peakStart,    1_000, 10_000, 500),
                (offPeakStart, 2_000, 20_000, 900),
            ]))
            let usage = window.models.first!

            check("window reports hourly", window.isHourly)
            check("model marked tiered", usage.tiered)
            checkEq("peak bucket landed in peak", usage.peakCacheMissTokens, 10_000)
            checkEq("off-peak bucket landed in off-peak", usage.offPeakCacheMissTokens, 20_000)
            checkEq("peak output separated", usage.peakOutputTokens, 500)
            checkEq("off-peak output separated", usage.offPeakOutputTokens, 900)
            checkEq("totals unchanged by splitting", usage.totalTokens, 1_000 + 10_000 + 500 + 2_000 + 20_000 + 900)
        } catch {
            checkEq("hourly decode threw: \(error)", false, true)
        }

        print("\nBoundary hours (the schedule edges):")
        // 00:59 UTC is off-peak, 01:00 UTC is peak — adjacent minutes, one
        // bucket each, so an off-by-one here would swap them.
        do {
            let window = try decode(payload(bucket: 3600, buckets: [
                (monday0000,                    111, 0, 0),   // 00:00-01:00 off-peak
                (monday0000 + 3600,             222, 0, 0),   // 01:00-02:00 peak
                (monday0000 + 4 * 3600,         333, 0, 0),   // 04:00-05:00 off-peak
                (monday0000 + 6 * 3600,         444, 0, 0),   // 06:00-07:00 peak
                (monday0000 + 10 * 3600,        555, 0, 0),   // 10:00-11:00 off-peak
            ]))
            let usage = window.models.first!
            checkEq("00:00 off-peak, 01:00 peak, 04:00 off, 06:00 peak, 10:00 off",
                    usage.offPeakCacheHitTokens, 111 + 333 + 555)
            checkEq("peak hours captured", usage.peakCacheHitTokens, 222 + 444)
        } catch {
            checkEq("boundary decode threw: \(error)", false, true)
        }

        print("\nIdentical traffic costs double in a peak hour:")
        // Same token counts in both buckets, so the only variable is the tier.
        do {
            let identical = (1_000, 10_000, 500)
            let window = try decode(payload(bucket: 3600, buckets: [
                (monday0000 + 2 * 3600,  identical.0, identical.1, identical.2),
                (monday0000 + 12 * 3600, identical.0, identical.1, identical.2),
            ]))
            let usage = window.models.first!
            checkEq("peak token counts equal off-peak", usage.peakTokens, usage.offPeakTokens)
            checkEq("peak costs exactly double off-peak",
                    usage.peakCost!, usage.offPeakCost! * 2)
        } catch {
            checkEq("ratio decode threw: \(error)", false, true)
        }

        print("\nWeekend buckets are off-peak:")
        // 2026-09-19 is a Saturday; 02:00 UTC would be peak on a weekday.
        do {
            let saturday0000 = monday0000 + 5 * 86400
            let window = try decode(payload(bucket: 3600, buckets: [
                (saturday0000 + 2 * 3600, 777, 0, 0),
            ]))
            let usage = window.models.first!
            checkEq("Saturday 02:00 is off-peak", usage.offPeakCacheHitTokens, 777)
            checkEq("and nothing is peak", usage.peakCacheHitTokens, 0)
        } catch {
            checkEq("weekend decode threw: \(error)", false, true)
        }

        print("\nBuckets outside the requested local day are dropped:")
        // The server window is whole UTC hours and whole days, so in a zone
        // with a non-hour offset — or across a DST change — it can reach into
        // the neighbouring local day. Those buckets must not be summed into
        // "Today by model". Judged in UTC here so the answer is deterministic.
        do {
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC")!
            let nextDay = monday0000 + 86_400
            let envelope = try JSONDecoder().decode(
                Envelope<AmountPayload>.self,
                from: payload(bucket: 3600, buckets: [
                    (monday0000 + 23 * 3600, 111, 0, 0),  // today 23:00
                    (nextDay,                222, 0, 0),  // tomorrow 00:00
                ]))
            let amount = envelope.data!.biz_data!
            let window = DeepSeekClient.merge(
                amount: amount, cost: nil,
                from: Date(timeIntervalSince1970: TimeInterval(monday0000)),
                to: Date(timeIntervalSince1970: TimeInterval(nextDay)),
                calendar: utcCalendar)
            let usage = window.models.first!
            checkEq("tomorrow's bucket is not counted today",
                    usage.offPeakCacheHitTokens, 111)
        } catch {
            checkEq("window-filter decode threw: \(error)", false, true)
        }

        print("\nDaily buckets are not claimed as tiered:")
        // A daily bucket spans both tiers, so the split must be declined
        // rather than invented.
        do {
            let window = try decode(payload(bucket: 86400, buckets: [
                (monday0000, 1_000, 1_000, 1_000),
            ]))
            let usage = window.models.first!
            check("window not hourly", !window.isHourly)
            check("model not marked tiered", !usage.tiered)
            checkEq("no peak cost claimed", usage.peakCost == nil, true)
            checkEq("no off-peak cost claimed", usage.offPeakCost == nil, true)
            checkEq("tokens still counted", usage.totalTokens, 3_000)
        } catch {
            checkEq("daily decode threw: \(error)", false, true)
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
