import Foundation

/// What the menu bar shows, and where "spent today" comes from.
///
/// The status item is the one part of the app that is always on screen, so
/// getting the composed string wrong is more visible than getting a popover
/// detail wrong. It is also the part with the least room for a dash or a
/// placeholder, which is what most of these assertions are about.

@main
struct MenuBarTests {
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

    static let d = Date(timeIntervalSince1970: 1789344000)

    // MARK: - Composition

    static func testCompose() {
        print("\nComposition:")
        let all: [MenuBarItem: String] = [.balance: "BAL", .countdown: "TIME", .spentToday: "SPEND"]

        checkEq("all three, in declaration order",
                MenuBarItem.compose(selected: [.balance, .countdown, .spentToday],
                                    values: all, fallback: "TIME"),
                "BAL · TIME · SPEND")

        // A Set has no order, so this is really asserting that the render
        // order comes from the enum and not from whatever the Set yielded.
        checkEq("selection order does not leak into display order",
                MenuBarItem.compose(selected: [.spentToday, .balance],
                                    values: all, fallback: "TIME"),
                "BAL · SPEND")

        checkEq("a single item is not joined",
                MenuBarItem.compose(selected: [.countdown], values: all, fallback: "TIME"),
                "TIME")

        checkEq("unavailable item is dropped, not dashed",
                MenuBarItem.compose(selected: [.balance, .countdown, .spentToday],
                                    values: [.balance: "BAL", .spentToday: "SPEND"],
                                    fallback: "TIME"),
                "BAL · SPEND")

        // Balance needs the API key and spend needs the platform token, so
        // "selected but nothing to show" is a real state, not a hypothetical.
        checkEq("empty selection shows the dot alone",
                MenuBarItem.compose(selected: [], values: all, fallback: "TIME"),
                "")

        checkEq("selection that produced nothing falls back",
                MenuBarItem.compose(selected: [.balance, .spentToday], values: [:], fallback: "TIME"),
                "TIME")

        checkEq("the fallback is not joined to anything",
                MenuBarItem.compose(selected: [.balance], values: [:], fallback: "TIME"),
                "TIME")
    }

    // MARK: - Spend totals

    static func window(_ models: [ModelUsage], bucket: Int = 3600) -> UsageWindow {
        UsageWindow(start: d, end: d, bucketSeconds: bucket, models: models)
    }

    static func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    static func testSpendTotal() {
        print("\nSpend total:")

        // DeepSeek's own figures, when the cost endpoint answered.
        var a = ModelUsage(model: "deepseek-flash"); a.cost = dec("0.12")
        var b = ModelUsage(model: "deepseek-v4-pro"); b.cost = dec("0.30")
        let reported = window([a, b]).cost
        checkEq("reported costs sum", reported?.amount, dec("0.42"))
        checkEq("reported total is not marked estimated", reported?.estimated, false)

        // No reported cost, so the rate table answers. flash off-peak is
        // $0.15 per 1M cache-miss tokens, so exactly 1M must land on 0.15.
        var computed = ModelUsage(model: "deepseek-flash")
        computed.offPeakCacheMissTokens = 1_000_000
        let estimated = window([computed]).cost
        checkEq("falls back to the rate table", estimated?.amount, dec("0.15"))
        checkEq("and is marked estimated", estimated?.estimated, true)

        var outputOnly = ModelUsage(model: "deepseek-flash")
        outputOnly.offPeakOutputTokens = 1_000_000
        checkEq("output tokens priced separately",
                window([outputOnly]).cost?.amount, dec("0.60"))

        // Mixed: part authoritative, part derived. The total must include
        // both and still admit that it is not wholly reported.
        var half = ModelUsage(model: "deepseek-flash")
        half.offPeakCacheMissTokens = 1_000_000
        var known = ModelUsage(model: "deepseek-v4-pro"); known.cost = dec("0.10")
        let mixed = window([half, known]).cost
        checkEq("mixed total adds both", mixed?.amount, dec("0.25"))
        checkEq("mixed total is marked estimated", mixed?.estimated, true)

        // A model we have no rates for and no reported cost contributes
        // nothing, which must leave the window undecided rather than $0.00.
        checkEq("unknown model alone leaves the total unknown",
                window([ModelUsage(model: "mystery-model")]).cost?.amount, nil)
        checkEq("no models at all leaves the total unknown", window([]).cost?.amount, nil)

        checkEq("zero usage is a real zero, not unknown",
                window([ModelUsage(model: "deepseek-flash")]).cost?.amount, Decimal.zero)
    }

    // MARK: - Persistence

    /// Each case gets its own suite so the legacy-key migration, which deletes
    /// as it goes, cannot leak into the next assertion.
    static func freshDefaults() -> UserDefaults {
        let name = "DeepSeekUsageBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func testPersistence() {
        print("\nStored selection:")

        checkEq("nothing stored defaults to the countdown",
                MenuBarItem.load(from: freshDefaults()), [.countdown])

        let stored = freshDefaults()
        stored.set(["balance", "spentToday"], forKey: MenuBarItem.defaultsKey)
        checkEq("a stored set is read back",
                MenuBarItem.load(from: stored), [.balance, .spentToday])

        let blank = freshDefaults()
        blank.set([String](), forKey: MenuBarItem.defaultsKey)
        checkEq("an empty stored set stays empty",
                MenuBarItem.load(from: blank), [])

        // Values from a future version must not silently blank the bar.
        let future = freshDefaults()
        future.set(["telemetry", "uptime"], forKey: MenuBarItem.defaultsKey)
        checkEq("unknown stored values fall back to the default",
                MenuBarItem.load(from: future), [.countdown])

        let legacyOn = freshDefaults()
        legacyOn.set(true, forKey: "showBalanceInMenuBar")
        checkEq("legacy 'balance on' becomes balance only",
                MenuBarItem.load(from: legacyOn), [.balance])
        checkEq("and the legacy key is cleared",
                legacyOn.object(forKey: "showBalanceInMenuBar") == nil, true)

        let legacyOff = freshDefaults()
        legacyOff.set(false, forKey: "showBalanceInMenuBar")
        checkEq("legacy 'balance off' becomes the countdown",
                MenuBarItem.load(from: legacyOff), [.countdown])

        // The new key wins, so a stale legacy value cannot resurrect itself.
        let both = freshDefaults()
        both.set(["spentToday"], forKey: MenuBarItem.defaultsKey)
        both.set(true, forKey: "showBalanceInMenuBar")
        checkEq("the new key takes precedence over the legacy one",
                MenuBarItem.load(from: both), [.spentToday])
    }

    static func main() {
        testCompose()
        testSpendTotal()
        testPersistence()

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
