import Foundation

/// Everything that talks to DeepSeek, in one place.
///
/// Two credentials are in play and they are not interchangeable:
///
///   - `sk-...` API key   -> the official `api.deepseek.com/user/balance`
///   - platform userToken -> the private `platform.deepseek.com/api/v0/*`
///
/// The private endpoints are undocumented and may change without notice, so
/// they are confined to this file. The response shapes below are not guesses:
/// they come from a real captured session (`platform.deepseek.com.har`) and
/// the 2026-09 shapes are recorded in the project notes.

// MARK: - Value types

struct Balance {
    var total: Decimal
    var granted: Decimal
    var toppedUp: Decimal
    var currency: String
    var isAvailable: Bool

    static let zero = Balance(total: 0, granted: 0, toppedUp: 0, currency: "USD", isAvailable: false)
}

/// One model's totals over a window, as the dashboard reports them.
///
/// Token counts are split by rate tier, which is only meaningful when the
/// window came back as hourly buckets — a daily bucket spans both tiers and
/// belongs to neither. `tiered` records whether that split can be trusted, so
/// the UI never presents a fabricated one.
struct ModelUsage: Identifiable {
    var model: String
    var requests: Int = 0

    var peakCacheHitTokens = 0
    var peakCacheMissTokens = 0
    var peakOutputTokens = 0
    var offPeakCacheHitTokens = 0
    var offPeakCacheMissTokens = 0
    var offPeakOutputTokens = 0

    /// True when the source buckets were hourly.
    var tiered = false

    /// DeepSeek's own figure for the window. Authoritative, and the only
    /// trustworthy cost when the tier split is unavailable.
    var cost: Decimal?

    var id: String { model }

    var cacheHitTokens: Int { peakCacheHitTokens + offPeakCacheHitTokens }
    var cacheMissTokens: Int { peakCacheMissTokens + offPeakCacheMissTokens }
    var outputTokens: Int { peakOutputTokens + offPeakOutputTokens }
    var totalTokens: Int { cacheHitTokens + cacheMissTokens + outputTokens }

    var peakTokens: Int { peakCacheHitTokens + peakCacheMissTokens + peakOutputTokens }
    var offPeakTokens: Int { offPeakCacheHitTokens + offPeakCacheMissTokens + offPeakOutputTokens }

    /// What the peak-hour portion cost at peak rates.
    var peakCost: Decimal? {
        guard tiered, peakTokens > 0, let rates = Pricing.rates(for: model) else { return nil }
        return Pricing.cost(cacheHitTokens: peakCacheHitTokens,
                            cacheMissTokens: peakCacheMissTokens,
                            outputTokens: peakOutputTokens,
                            rates: rates, isPeak: true)
    }

    /// What the off-peak portion cost — the same tokens at half the rate.
    var offPeakCost: Decimal? {
        guard tiered, offPeakTokens > 0, let rates = Pricing.rates(for: model) else { return nil }
        return Pricing.cost(cacheHitTokens: offPeakCacheHitTokens,
                            cacheMissTokens: offPeakCacheMissTokens,
                            outputTokens: offPeakOutputTokens,
                            rates: rates, isPeak: false)
    }
}

/// A usage response, plus the granularity the server chose for it.
struct UsageWindow {
    var start: Date
    var end: Date
    /// Server-reported bucket width in seconds. 86400 means the window came
    /// back as daily totals; 3600 would mean hourly, which is what peak /
    /// off-peak attribution needs. Never assumed — always read from the reply.
    var bucketSeconds: Int
    var models: [ModelUsage]

    var isHourly: Bool { bucketSeconds <= 3600 }

    /// Total spend for the window.
    ///
    /// Prefers DeepSeek's own reported figure and falls back to the rate table
    /// for any model it did not report. `estimated` is true when any part of
    /// the total came from that arithmetic, which prices everything at
    /// off-peak and is therefore a lower bound — worth marking, since the
    /// figure is otherwise presented with the same confidence as the
    /// authoritative one.
    var cost: (amount: Decimal, estimated: Bool)? {
        var total = Decimal.zero
        var estimated = false
        var counted = 0
        for model in models {
            if let reported = model.cost {
                total += reported
                counted += 1
            } else if let rates = Pricing.rates(for: model.model) {
                total += Pricing.cost(cacheHitTokens: model.cacheHitTokens,
                                      cacheMissTokens: model.cacheMissTokens,
                                      outputTokens: model.outputTokens,
                                      rates: rates,
                                      isPeak: false)
                estimated = true
                counted += 1
            }
        }
        return counted == 0 ? nil : (total, estimated)
    }
}

/// One local day's spend, as the dashboard reported it.
struct DailySpend: Identifiable, Equatable {
    /// Local midnight — the day this belongs to. Also the identity, since a
    /// series holds exactly one entry per day.
    var day: Date
    var cost: Decimal
    /// True when any of `cost` came from the rate table rather than from
    /// DeepSeek's own figure. That arithmetic prices everything at off-peak, so
    /// an estimated day is a lower bound and is marked as one wherever it is
    /// shown, exactly as `UsageWindow.cost` does for a single day.
    var estimated: Bool
    var requests: Int
    var tokens: Int

    var id: Date { day }
}

/// A multi-day window folded to one entry per local day.
///
/// The dashboard answers a week or a month with a single daily bucket per
/// model, and a daily bucket spans both rate tiers — so unlike `UsageWindow`
/// this type carries no peak/off-peak split. There is nothing honest to split.
struct SpendSeries {
    var start: Date
    var end: Date
    /// Server-reported bucket width in seconds, as in `UsageWindow`. Daily for
    /// every range the app asks for, but read from the reply rather than
    /// assumed, so a narrower bucket still folds onto the right day.
    var bucketSeconds: Int
    /// One entry per local day in the window, oldest first. Days DeepSeek did
    /// not report are present at zero rather than omitted, so the chart draws
    /// an idle day as a gap instead of shifting every later day one place left.
    var days: [DailySpend]

    var isEmpty: Bool { days.allSatisfy { $0.cost == 0 && $0.requests == 0 } }

    var total: (amount: Decimal, estimated: Bool) {
        var amount = Decimal.zero
        var estimated = false
        for day in days {
            amount += day.cost
            if day.estimated { estimated = true }
        }
        return (amount, estimated)
    }

    /// Mean spend per day across the whole window, including days with no
    /// spend. Averaging only the days that had traffic would let one busy
    /// afternoon stand in for a fortnight.
    var dailyAverage: Decimal {
        days.isEmpty ? 0 : total.amount / Decimal(days.count)
    }

    var busiest: DailySpend? {
        days.filter { $0.cost > 0 }.max { $0.cost < $1.cost }
    }

    /// Largest single day, for scaling the chart's y-axis. Zero when there is
    /// nothing to plot, which callers must not divide by.
    var busiestCost: Decimal { busiest?.cost ?? 0 }
}

enum DeepSeekError: LocalizedError {
    case missingCredential(String)
    case unauthorized
    /// The dashboard refused the credential. Separate from `unauthorized`
    /// because DeepSeek does not use HTTP status for this: it answers 200 and
    /// puts the reason in the envelope, so a dead token never looks like a 401.
    case tokenRejected(code: Int, message: String)
    case rateLimited
    case http(Int)
    case api(code: Int, message: String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let what): return "No \(what) set."
        case .unauthorized: return "Token rejected (401/403). It has probably expired — paste a fresh one."
        case .tokenRejected(let code, let message):
            let detail = message.isEmpty ? "" : " DeepSeek said: \(message)"
            return "Platform token rejected (\(code)) — it has expired or been replaced. "
                 + "Paste a fresh one from platform.deepseek.com.\(detail)"
        case .rateLimited: return "Rate limited (429). Try again shortly."
        case .http(let code): return "Unexpected response (HTTP \(code))."
        case .api(let code, let message): return "DeepSeek returned error \(code): \(message)"
        case .malformed(let detail): return "Could not parse the response: \(detail)"
        }
    }

    /// True when the credential itself was refused, so the caller should stop
    /// sending it and ask for a new one rather than retrying the same dead
    /// value on every refresh.
    var isTokenRejection: Bool {
        switch self {
        case .tokenRejected, .unauthorized: return true
        default: return false
        }
    }
}

// MARK: - Wire format

/// `{ "code": 0, "msg": "", "data": { "biz_code": 0, "biz_msg": "", "biz_data": … } }`
struct Envelope<Payload: Decodable>: Decodable {
    let code: Int
    let msg: String?
    let data: Inner?

    struct Inner: Decodable {
        let biz_code: Int?
        let biz_msg: String?
        let biz_data: Payload?
    }
}

struct APIKeyRef: Decodable {
    let tracking_id: String?
    let name: String?
    let sensitive_id: String?
    let valid: Bool?
}

/// `/api/v0/usage/by_api_key/amount`
struct AmountPayload: Decodable {
    let start: Int
    let end: Int
    let bucket: Int
    let series: [Series]

    struct Series: Decodable {
        let api_key: APIKeyRef?
        let model: String
        let buckets: [Bucket]
    }
    struct Bucket: Decodable {
        let time: Int
        let usage: Usage
    }
    struct Usage: Decodable {
        let RESPONSE_TOKEN: Int?
        let REQUEST: Int?
        let PROMPT_CACHE_HIT_TOKEN: Int?
        let PROMPT_CACHE_MISS_TOKEN: Int?
    }
}

/// `/api/v0/usage/by_api_key/cost`
struct CostPayload: Decodable {
    let start: Int
    let end: Int
    let bucket: Int
    let data: [CurrencyBlock]

    struct CurrencyBlock: Decodable {
        let currency: String
        let series: [Series]
    }
    struct Series: Decodable {
        let api_key: APIKeyRef?
        let model: String
        let buckets: [Bucket]
    }
    struct Bucket: Decodable {
        let time: Int
        let cost: String
    }
}

// MARK: - Client

struct DeepSeekClient {
    /// The dashboard rejects requests that do not look like its own frontend,
    /// so the browser-ish headers are load-bearing, not decoration.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      + "(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"

    var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    // MARK: Balance (official API, sk- key)

    func fetchBalance(apiKey: String) async throws -> Balance {
        guard !apiKey.isEmpty else { throw DeepSeekError.missingCredential("API key") }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        try check(response)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]] else {
            throw DeepSeekError.malformed("no balance_infos")
        }
        // Prefer USD when the account holds several currencies.
        let info = infos.first { ($0["currency"] as? String)?.uppercased() == "USD" } ?? infos.first ?? [:]
        return Balance(
            total: decimal(info["total_balance"]),
            granted: decimal(info["granted_balance"]),
            toppedUp: decimal(info["topped_up_balance"]),
            currency: (info["currency"] as? String) ?? "USD",
            isAvailable: (root["is_available"] as? Bool) ?? false
        )
    }

    // MARK: Usage (private dashboard, userToken)

    /// Per-model usage and cost between two instants.
    ///
    /// `tz` is the caller's UTC offset **in seconds** (7200 for CEST). The
    /// dashboard uses it to decide which local day a bucket belongs to, and
    /// it sends the same value as `x-client-timezone-offset`.
    func fetchUsage(userToken: String, from start: Date, to end: Date) async throws -> UsageWindow {
        guard !userToken.isEmpty else { throw DeepSeekError.missingCredential("platform token") }

        let window = Self.serverWindow(from: start, to: end)
        let tz = TimeZone.current.secondsFromGMT(for: window.start)
        let s = Int(window.start.timeIntervalSince1970)
        let e = Int(window.end.timeIntervalSince1970)

        async let amount = fetchJSON(AmountPayload.self, token: userToken,
                                     path: "/api/v0/usage/by_api_key/amount", start: s, end: e, tz: tz)
        async let cost = fetchJSON(CostPayload.self, token: userToken,
                                   path: "/api/v0/usage/by_api_key/cost", start: s, end: e, tz: tz)

        let amountPayload = try await amount
        // Cost is enrichment: a failure there should not lose the token counts.
        let costPayload = try? await cost

        return Self.merge(amount: amountPayload, cost: costPayload, from: start, to: end)
    }

    /// Folds a one-day response into per-model totals.
    ///
    /// `start` and `end` are the *requested* window, not the one actually put
    /// on the wire. The endpoint requires whole UTC hours and whole 86400-
    /// second days, so in a zone whose offset is not a whole hour, or across a
    /// DST change, the server window reaches up to an hour outside the local
    /// day that was asked for. Buckets outside that day are dropped here, so
    /// tomorrow's first half hour cannot land in "Today by model".
    static func merge(
        amount: AmountPayload,
        cost: CostPayload?,
        from start: Date? = nil,
        to end: Date? = nil,
        calendar: Calendar = .current
    ) -> UsageWindow {
        var byModel: [String: ModelUsage] = [:]
        // Only hourly buckets can be attributed to a rate tier. A daily bucket
        // straddles both, so its tokens go to neither.
        let tiered = amount.bucket <= 3600

        let firstDay = start.map { calendar.startOfDay(for: $0) }
        let lastDay = end.map { calendar.startOfDay(for: $0) }
        func belongsToWindow(_ time: Int) -> Bool {
            guard let firstDay, let lastDay else { return true }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(time)))
            return day >= firstDay && day < lastDay
        }

        for series in amount.series {
            var entry = byModel[series.model] ?? ModelUsage(model: series.model)
            entry.tiered = tiered
            for bucket in series.buckets where belongsToWindow(bucket.time) {
                let hit = bucket.usage.PROMPT_CACHE_HIT_TOKEN ?? 0
                let miss = bucket.usage.PROMPT_CACHE_MISS_TOKEN ?? 0
                let out = bucket.usage.RESPONSE_TOKEN ?? 0
                entry.requests += bucket.usage.REQUEST ?? 0

                if tiered, PeakSchedule.isPeak(Date(timeIntervalSince1970: TimeInterval(bucket.time))) {
                    entry.peakCacheHitTokens += hit
                    entry.peakCacheMissTokens += miss
                    entry.peakOutputTokens += out
                } else {
                    entry.offPeakCacheHitTokens += hit
                    entry.offPeakCacheMissTokens += miss
                    entry.offPeakOutputTokens += out
                }
            }
            byModel[series.model] = entry
        }

        // Prefer USD if the account reports in several currencies; otherwise
        // take whatever single currency came back.
        //
        // The cost endpoint returns one series per (API key, model), while
        // `byModel` is keyed by model alone. Several keys that ran the same
        // model therefore land on the same entry, so their totals must be
        // added — assigning would keep only the last key's figure. The chart's
        // fold accumulates across series the same way, and the two views
        // disagreeing is how that overwrite was found.
        if let cost {
            let block = cost.data.first { $0.currency.uppercased() == "USD" } ?? cost.data.first
            for series in block?.series ?? [] {
                var total = Decimal.zero
                for bucket in series.buckets where belongsToWindow(bucket.time) {
                    total += Decimal(string: bucket.cost) ?? 0
                }
                var entry = byModel[series.model] ?? ModelUsage(model: series.model)
                entry.cost = (entry.cost ?? 0) + total
                entry.tiered = tiered
                byModel[series.model] = entry
            }
        }

        return UsageWindow(
            start: Date(timeIntervalSince1970: TimeInterval(amount.start)),
            end: Date(timeIntervalSince1970: TimeInterval(amount.end)),
            bucketSeconds: amount.bucket,
            models: byModel.values.filter { $0.totalTokens > 0 || $0.requests > 0 }
                                .sorted { $0.totalTokens > $1.totalTokens }
        )
    }

    /// Per-day spend across a multi-day window, for the chart.
    ///
    /// Separate from `fetchUsage` rather than a parameter on it, because the
    /// two want opposite things from the same endpoint. A one-day window is
    /// what makes the server return *hourly* buckets, which is the only way
    /// peak and off-peak spend can be told apart; a week or a month comes back
    /// daily, which is what makes a trend cheap to fetch. One window cannot
    /// give both, so the popover makes both calls.
    func fetchSpendSeries(
        userToken: String,
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) async throws -> SpendSeries {
        guard !userToken.isEmpty else { throw DeepSeekError.missingCredential("platform token") }

        let window = Self.serverWindow(from: start, to: end)
        let tz = TimeZone.current.secondsFromGMT(for: window.start)
        let s = Int(window.start.timeIntervalSince1970)
        let e = Int(window.end.timeIntervalSince1970)

        async let amount = fetchJSON(AmountPayload.self, token: userToken,
                                     path: "/api/v0/usage/by_api_key/amount", start: s, end: e, tz: tz)
        async let cost = fetchJSON(CostPayload.self, token: userToken,
                                   path: "/api/v0/usage/by_api_key/cost", start: s, end: e, tz: tz)

        let amountPayload = try await amount
        // As in `fetchUsage`: cost is enrichment, and losing it should not
        // cost us the token counts.
        let costPayload = try? await cost

        return Self.spendSeries(amount: amountPayload, cost: costPayload,
                                from: start, to: end, calendar: calendar)
    }

    /// Folds a multi-day response into one entry per local day.
    ///
    /// Buckets are grouped by *local* day rather than by trusting the reply to
    /// be daily, so a narrower bucket — an hourly answer to a short range —
    /// still lands on the right bar.
    ///
    /// Cost is taken per model per day: DeepSeek's figure where it reported
    /// one, and the rate table otherwise, which marks the day as estimated.
    /// Only a model-day with no reported cost can be estimated, so a day
    /// DeepSeek priced in full is never downgraded to a guess.
    static func spendSeries(
        amount: AmountPayload,
        cost: CostPayload?,
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> SpendSeries {
        // What DeepSeek said each model cost on each day.
        var reported: [Date: [String: Decimal]] = [:]
        if let cost {
            let block = cost.data.first { $0.currency.uppercased() == "USD" } ?? cost.data.first
            for series in block?.series ?? [] {
                for bucket in series.buckets {
                    let day = calendar.startOfDay(
                        for: Date(timeIntervalSince1970: TimeInterval(bucket.time)))
                    reported[day, default: [:]][series.model, default: 0] += Decimal(string: bucket.cost) ?? 0
                }
            }
        }

        var byDay: [Date: DailySpend] = [:]
        func blank(_ day: Date) -> DailySpend {
            DailySpend(day: day, cost: 0, estimated: false, requests: 0, tokens: 0)
        }

        for series in amount.series {
            for bucket in series.buckets {
                let day = calendar.startOfDay(
                    for: Date(timeIntervalSince1970: TimeInterval(bucket.time)))
                var entry = byDay[day] ?? blank(day)
                let hit = bucket.usage.PROMPT_CACHE_HIT_TOKEN ?? 0
                let miss = bucket.usage.PROMPT_CACHE_MISS_TOKEN ?? 0
                let out = bucket.usage.RESPONSE_TOKEN ?? 0
                entry.requests += bucket.usage.REQUEST ?? 0
                entry.tokens += hit + miss + out

                // Tokens and requests are per bucket; DeepSeek's own cost is
                // applied below, once per model-day. Adding it here would
                // repeat the day's figure for every bucket the amount endpoint
                // split that day into — and a one-day window (which "This
                // month" becomes on the 1st) comes back hourly.
                if reported[day]?[series.model] == nil,
                   let rates = Pricing.rates(for: series.model) {
                    let fallback = Pricing.cost(cacheHitTokens: hit, cacheMissTokens: miss,
                                                outputTokens: out, rates: rates, isPeak: false)
                    entry.cost += fallback
                    // The dashboard does emit buckets with no tokens at all, and
                    // those price to zero. A zero that needed no guesswork is
                    // not evidence that anything was estimated — flagging it
                    // would put a "≥" on a window DeepSeek priced in full.
                    if fallback != 0 { entry.estimated = true }
                }
                byDay[day] = entry
            }
        }

        // Apply each model-day's reported cost exactly once. The two endpoints
        // are separate calls and can disagree about which days they cover, so a
        // day DeepSeek priced but reported no tokens for still belongs on the
        // chart — this creates those days rather than only updating existing
        // ones.
        for (day, models) in reported {
            var entry = byDay[day] ?? blank(day)
            entry.cost += models.values.reduce(Decimal.zero, +)
            byDay[day] = entry
        }

        var days: [DailySpend] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            days.append(byDay[day] ?? blank(day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return SpendSeries(start: start, end: end, bucketSeconds: amount.bucket, days: days)
    }

    /// The bounds actually put on the wire, given the local days a caller
    /// wants.
    ///
    /// The endpoint accepts only a request whose bounds both sit on a whole
    /// hour and whose span is a whole number of 86400-second days; anything
    /// else comes back as `code 1, INVALID_PARAM`, inside an HTTP 200. Local
    /// midnights meet that on an ordinary day, but a window that straddles a
    /// daylight-saving change does not: the day it happens is 23 or 25 hours
    /// long, so `midnight .. midnight` across it is a day plus or minus an
    /// hour and the whole request is refused.
    ///
    /// The end is kept — today is always the last day drawn, so it is the
    /// boundary that matters — and the start is moved off its midnight by as
    /// much as the span is off a whole day. That trims at most one hour from
    /// the oldest day, at its outer edge, which is the least visible place to
    /// lose it.
    ///
    /// In a zone whose UTC offset is not a whole hour the two rules cannot
    /// both hold against local midnight: a whole-day window on whole UTC
    /// hours is always half an hour off it. Rounding then keeps the most
    /// recent part of the day and leaves its first half hour on the wire
    /// outside the window; `merge` filters the other end so only the
    /// requested local day's buckets are counted.
    static func serverWindow(from start: Date, to end: Date) -> (start: Date, end: Date) {
        // Whole hours, so a zone with a non-hour offset still produces a
        // request the endpoint will look at.
        let alignedEnd = Date(timeIntervalSince1970:
            (end.timeIntervalSince1970 / 3600).rounded() * 3600)
        // Rounding, not truncating: a DST week is 7 days ± an hour, and both
        // answer 7 here. The span is then rebuilt exactly, so the server's
        // whole-days rule holds without the caller's local-day arithmetic
        // leaking into it.
        let days = max(1, Int((alignedEnd.timeIntervalSince(start) / 86_400).rounded()))
        return (alignedEnd.addingTimeInterval(-Double(days) * 86_400), alignedEnd)
    }

    private func fetchJSON<T: Decodable>(
        _ type: T.Type, token: String, path: String, start: Int, end: Int, tz: Int
    ) async throws -> T {
        var comps = URLComponents(string: "https://platform.deepseek.com" + path)!
        comps.queryItems = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "end", value: String(end)),
            URLQueryItem(name: "tz", value: String(tz)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("web", forHTTPHeaderField: "x-client-platform")
        req.setValue("1.0.0", forHTTPHeaderField: "x-client-version")
        req.setValue("com.deepseek.chat", forHTTPHeaderField: "x-client-bundle-id")
        req.setValue("en_US", forHTTPHeaderField: "x-client-locale")
        req.setValue(String(tz), forHTTPHeaderField: "x-client-timezone-offset")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://platform.deepseek.com", forHTTPHeaderField: "Origin")
        req.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        try check(response)

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw DeepSeekError.malformed("envelope did not match: \(error.localizedDescription)")
        }

        // Check both levels. A rejected token comes back as HTTP 200 with
        // `code != 0` and `data: null`, so the outer code is the one that
        // carries the reason — and its `msg` is the only explanation DeepSeek
        // gives, so it must reach the user rather than being swallowed.
        if let error = Self.envelopeError(code: envelope.code, msg: envelope.msg,
                                          bizCode: envelope.data?.biz_code,
                                          bizMsg: envelope.data?.biz_msg) {
            throw error
        }
        guard let payload = envelope.data?.biz_data else {
            throw DeepSeekError.malformed("code 0 but no biz_data")
        }
        return payload
    }

    /// The envelope's two code levels, turned into an error when either one
    /// refuses the request. Nil means the payload is usable.
    ///
    /// The outer `code` wins because it is the one that carries a credential
    /// rejection — that arrives with `data: null`, so there is no inner code
    /// to read at all.
    static func envelopeError(code: Int, msg: String?,
                              bizCode: Int?, bizMsg: String?) -> DeepSeekError? {
        if code != 0 { return apiError(code: code, message: msg ?? "") }
        if let bizCode, bizCode != 0 { return apiError(code: bizCode, message: bizMsg ?? msg ?? "") }
        return nil
    }

    /// Codes the dashboard uses when it will not accept the credential:
    /// 40002 no token presented, 40003 invalid — expired reads the same, since
    /// the console has no separate code for it. Both arrive inside an HTTP 200.
    static let tokenRejectionCodes: Set<Int> = [40002, 40003]

    static func apiError(code: Int, message: String) -> DeepSeekError {
        tokenRejectionCodes.contains(code)
            ? .tokenRejected(code: code, message: message)
            : .api(code: code, message: message)
    }

    /// The dashboard's stored value is not always a bare token, and what
    /// people paste is not always what the field wants. Handles the common
    /// shapes so a 40003 is a real rejection rather than a formatting mistake:
    /// a `Bearer ` prefix, a JSON object like `{"value":"eyJ..."}`, or a
    /// quoted JSON string literal.
    static func normalizeToken(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Run to a fixed point rather than applying each rule once. The
        // wrappers nest in practice — `Bearer {"value":"…%3D"}` needs the
        // prefix and the JSON shell removed before the escapes can be seen —
        // so a single ordered pass leaves the token half-unwrapped.
        for _ in 0..<4 {
            let before = t
            t = stripBearerPrefix(t)
            t = unwrapJSONValue(t)
            t = unquote(t)
            t = percentDecodeOnce(t)
            if t == before { break }
        }

        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBearerPrefix(_ s: String) -> String {
        s.lowercased().hasPrefix("bearer ")
            ? String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            : s
    }

    /// A JSON wrapper, e.g. `{"value":"eyJ..."}`.
    private static func unwrapJSONValue(_ s: String) -> String {
        guard s.hasPrefix("{"), let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return s }
        for key in ["value", "token", "userToken", "access_token", "accessToken"] {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        return s
    }

    /// A quoted JSON string literal.
    private static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"")
            ? String(s.dropFirst().dropLast())
            : s
    }

    /// A JWT is base64url plus '=' padding, so it never legitimately contains
    /// '%'. But DevTools' Network tab renders values percent-encoded, turning
    /// the trailing '=' into %3D — and a token pasted from there looks right
    /// while authenticating as nothing.
    private static func percentDecodeOnce(_ s: String) -> String {
        guard s.contains("%"), let decoded = s.removingPercentEncoding, decoded != s
        else { return s }
        return decoded
    }

    // MARK: - Helpers

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw DeepSeekError.unauthorized
        case 429: throw DeepSeekError.rateLimited
        default: throw DeepSeekError.http(http.statusCode)
        }
    }

    private func decimal(_ v: Any?) -> Decimal {
        if let d = v as? Double { return Decimal(d) }
        if let i = v as? Int { return Decimal(i) }
        if let s = v as? String { return Decimal(string: s) ?? 0 }
        return 0
    }
}
