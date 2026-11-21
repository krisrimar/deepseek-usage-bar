import Foundation

/// DeepSeek's published rates, in USD per 1M tokens.
///
/// Off-peak is exactly half of peak across every category, so it is derived
/// rather than tabulated — one number to update if prices move, not two.
///
/// Source: https://api-docs.deepseek.com/quick_start/pricing
struct ModelRates {
    let cacheHit: Decimal
    let cacheMiss: Decimal
    let output: Decimal

    var offPeak: ModelRates {
        ModelRates(cacheHit: cacheHit / 2, cacheMiss: cacheMiss / 2, output: output / 2)
    }
}

enum Pricing {
    /// Maps a reported model string onto its rates.
    ///
    /// The dashboard and the API disagree about names — the API accepts the
    /// undocumented alias `deepseek-v4-flash` and echoes it straight back,
    /// while the dashboard reports `deepseek-flash`. Both land here.
    static func rates(for model: String) -> ModelRates? {
        let m = model.lowercased()
        if m.contains("pro") {
            return ModelRates(cacheHit: dec("0.044"), cacheMiss: dec("1.32"), output: dec("3.96"))
        }
        if m.contains("flash") {
            return ModelRates(cacheHit: dec("0.006"), cacheMiss: dec("0.30"), output: dec("1.20"))
        }
        return nil
    }

    /// Cost in USD for a token split, at the given rate tier.
    ///
    /// Decimal throughout: these are money amounts and the token counts get
    /// large, so binary floating point drift is not worth tolerating.
    static func cost(
        cacheHitTokens: Int,
        cacheMissTokens: Int,
        outputTokens: Int,
        rates: ModelRates,
        isPeak: Bool
    ) -> Decimal {
        let r = isPeak ? rates : rates.offPeak
        let million = dec("1000000")
        return (dec(cacheHitTokens) * r.cacheHit
              + dec(cacheMissTokens) * r.cacheMiss
              + dec(outputTokens) * r.output) / million
    }

    private static func dec(_ s: String) -> Decimal { Decimal(string: s)! }
    private static func dec(_ i: Int) -> Decimal { Decimal(i) }

    static func usd(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        // Small spends are common, so never round a real cost away to $0.00.
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = amount < dec("0.01") && amount > 0 ? 4 : 2
        return f.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }
}
