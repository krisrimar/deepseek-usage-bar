import Foundation

/// Decodes a captured `platform.deepseek.com` HAR through the real client
/// types, so the wire format is verified against an actual server response
/// rather than a guess.
///
/// The HAR is user data (it contains real usage figures and a masked key) and
/// is gitignored, so this SKIPS rather than fails when it is absent — a
/// missing capture is not a broken build.
///
/// Usage: ./tests/run.sh [path/to/capture.har]

@main
struct UsageDecodeTests {
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

    /// Pulls the response body of the first entry whose URL contains `match`.
    static func response(in har: [String: Any], matching match: String) -> Data? {
        guard let log = har["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let request = entry["request"] as? [String: Any],
                  let url = request["url"] as? String, url.contains(match),
                  let response = entry["response"] as? [String: Any],
                  let content = response["content"] as? [String: Any],
                  let text = content["text"] as? String else { continue }
            return text.data(using: .utf8)
        }
        return nil
    }

    static func main() {
        let path = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "platform.deepseek.com.har"

        guard let raw = FileManager.default.contents(atPath: path),
              let har = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            print("\nSKIP: no readable HAR at \(path)")
            print("Capture one from platform.deepseek.com/usage and pass its path.\n")
            exit(0)
        }

        print("\nDecoding captured responses from \(path)")

        guard let amountData = response(in: har, matching: "/usage/by_api_key/amount") else {
            print("  FAIL  no amount response found in the capture")
            exit(1)
        }
        guard let costData = response(in: har, matching: "/usage/by_api_key/cost") else {
            print("  FAIL  no cost response found in the capture")
            exit(1)
        }

        let decoder = JSONDecoder()
        let amountEnvelope: Envelope<AmountPayload>
        let costEnvelope: Envelope<CostPayload>
        do {
            amountEnvelope = try decoder.decode(Envelope<AmountPayload>.self, from: amountData)
            costEnvelope = try decoder.decode(Envelope<CostPayload>.self, from: costData)
        } catch {
            print("  FAIL  decoding threw: \(error)")
            exit(1)
        }

        checkEq("envelope code is 0", amountEnvelope.code, 0)
        guard let amount = amountEnvelope.data?.biz_data,
              let cost = costEnvelope.data?.biz_data else {
            print("  FAIL  no biz_data in one of the envelopes")
            exit(1)
        }
        checkEq("biz_code is 0", amountEnvelope.data?.biz_code ?? -1, 0)

        // The server chose daily buckets for a ~19-day window. This is the
        // fact that decides whether peak/off-peak cost can be attributed
        // exactly, so it is worth asserting rather than eyeballing.
        checkEq("bucket is daily (86400s)", amount.bucket, 86400)

        let window = DeepSeekClient.merge(amount: amount, cost: cost)
        let byModel = Dictionary(uniqueKeysWithValues: window.models.map { ($0.model, $0) })

        checkEq("models with usage", window.models.count, 3)
        checkEq("isHourly", window.isHourly, false)

        // Exact figures from the capture.
        if let flash = byModel["deepseek-flash"] {
            checkEq("deepseek-flash requests", flash.requests, 8393)
            checkEq("deepseek-flash cache-hit tokens", flash.cacheHitTokens, 623_198_975)
            checkEq("deepseek-flash cache-miss tokens", flash.cacheMissTokens, 16_577_224)
            checkEq("deepseek-flash output tokens", flash.outputTokens, 3_687_279)
        } else {
            checkEq("deepseek-flash present", false, true)
        }

        if let v4 = byModel["deepseek-v4-flash"] {
            checkEq("deepseek-v4-flash requests", v4.requests, 1193)
            checkEq("deepseek-v4-flash output tokens", v4.outputTokens, 907_249)
        } else {
            checkEq("deepseek-v4-flash present", false, true)
        }

        // The model the console showed usage for, but the client config never
        // names. Its presence here is the evidence, not an assumption.
        if let pro = byModel["deepseek-v4-pro"] {
            checkEq("deepseek-v4-pro requests", pro.requests, 402)
            checkEq("deepseek-v4-pro output tokens", pro.outputTokens, 369_947)
        } else {
            checkEq("deepseek-v4-pro present", false, true)
        }

        // Tokens we never asked about must not appear.
        let allNames = window.models.map(\.model)
        checkEq("no phantom models", allNames.filter { !$0.contains("deepseek") }.isEmpty, true)

        // The same capture through the chart's folding path. The capture was
        // requested with tz=7200 (CEST), so it is folded with a Vienna calendar
        // — the machine's own zone would put the buckets on the wrong days.
        var vienna = Calendar(identifier: .gregorian)
        vienna.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let spend = DeepSeekClient.spendSeries(
            amount: amount, cost: cost,
            from: Date(timeIntervalSince1970: TimeInterval(amount.start)),
            to: Date(timeIntervalSince1970: TimeInterval(amount.end)),
            calendar: vienna)

        checkEq("the chart gets one bar per day", spend.days.count, 19)

        // Summed straight off the raw payload, so this is a cross-check of the
        // folding rather than a restatement of it.
        let usd = cost.data.first { $0.currency.uppercased() == "USD" } ?? cost.data.first
        var expected = Decimal.zero
        for s in usd?.series ?? [] {
            for b in s.buckets { expected += Decimal(string: b.cost) ?? 0 }
        }
        checkEq("and their total is every reported cost added up",
                spend.total.amount, expected)

        // The dashboard names models identically in both endpoints, so nothing
        // in this capture should have needed the rate table. A model-name
        // mismatch would show up here as a silently estimated window.
        checkEq("no day needed the fallback rate table", spend.total.estimated, false)

        print("\n  models found: \(allNames.joined(separator: ", "))")
        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
