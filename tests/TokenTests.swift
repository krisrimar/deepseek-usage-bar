import Foundation

/// Tests for pasted-token normalisation.
///
/// Worth having because every failure mode here looks identical from the
/// outside: DeepSeek returns "Authorization Failed (invalid token)" whether
/// the token is expired, truncated, JSON-wrapped, or percent-encoded. That
/// ambiguity cost a debugging round-trip, so the shapes are pinned down.

@main
struct TokenTests {
    static var passed = 0
    static var failed = 0

    static func checkEq(_ label: String, _ actual: String, _ expected: String) {
        if actual == expected {
            passed += 1
            print("  ok    \(label)")
        } else {
            failed += 1
            print("  FAIL  \(label)\n          expected: \(expected)\n          got:      \(actual)")
        }
    }

    static func check(_ label: String, _ condition: Bool) {
        if condition {
            passed += 1
            print("  ok    \(label)")
        } else {
            failed += 1
            print("  FAIL  \(label)")
        }
    }

    /// What the app does with an error: a credential it should throw away, or
    /// a failure it should keep retrying with the same token.
    static func rejectionLabel(_ error: DeepSeekError?) -> String {
        guard let error else { return "no error" }
        return error.isTokenRejection ? "drop the token" : "keep the token"
    }

    /// A decoded envelope, as `fetchJSON` sees it before the payload check.
    static func envelope(_ code: Int, _ msg: String? = nil,
                         bizCode: Int? = nil, bizMsg: String? = nil) -> DeepSeekError? {
        DeepSeekClient.envelopeError(code: code, msg: msg, bizCode: bizCode, bizMsg: bizMsg)
    }

    static func main() {
        // A realistic base64url JWT, '=' padded, as the dashboard stores it.
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk="
        let percentEncoded = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk%3D"

        print("\nToken normalisation:")

        checkEq("plain JWT passes through", DeepSeekClient.normalizeToken(jwt), jwt)
        checkEq("surrounding whitespace trimmed",
                DeepSeekClient.normalizeToken("  \(jwt)\n"), jwt)

        // The bug that actually bit: copying from the Network tab, where the
        // trailing base64 padding shows up as %3D.
        checkEq("percent-encoded padding decoded",
                DeepSeekClient.normalizeToken(percentEncoded), jwt)

        checkEq("Bearer prefix stripped",
                DeepSeekClient.normalizeToken("Bearer \(jwt)"), jwt)
        checkEq("lowercase bearer stripped",
                DeepSeekClient.normalizeToken("bearer \(jwt)"), jwt)

        checkEq("JSON wrapper unwrapped",
                DeepSeekClient.normalizeToken("{\"value\":\"\(jwt)\"}"), jwt)
        checkEq("JSON wrapper with userToken key",
                DeepSeekClient.normalizeToken("{\"userToken\":\"\(jwt)\"}"), jwt)
        checkEq("quoted string literal unwrapped",
                DeepSeekClient.normalizeToken("\"\(jwt)\""), jwt)

        // Combined, since pasting from DevTools can hit several at once.
        checkEq("Bearer + JSON + percent-encoded",
                DeepSeekClient.normalizeToken("Bearer {\"value\":\"\(percentEncoded)\"}"), jwt)

        // Must not damage anything it does not recognise.
        checkEq("empty stays empty", DeepSeekClient.normalizeToken(""), "")
        checkEq("garbage untouched", DeepSeekClient.normalizeToken("not-a-token"),
                "not-a-token")
        checkEq("sk- key untouched",
                DeepSeekClient.normalizeToken("sk-00000000000000000000000000000000"),
                "sk-00000000000000000000000000000000")
        // '=' padding alone must survive; only '%' escapes trigger decoding.
        checkEq("bare '=' preserved",
                DeepSeekClient.normalizeToken("abc="), "abc=")

        // The rejection path that actually fires in practice: DeepSeek answers
        // HTTP 200 and puts 40003 in the envelope, so the app must key off the
        // code rather than the status. Getting this wrong meant a dead token
        // was re-sent every five minutes with no prompt to replace it.
        print("\nCredential rejection:")
        checkEq("40003 -> drop the token", rejectionLabel(envelope(40003, "Authorization Failed")),
                "drop the token")
        checkEq("40002 -> drop the token", rejectionLabel(envelope(40002)), "drop the token")
        checkEq("biz_code 40003 -> drop the token",
                rejectionLabel(envelope(0, bizCode: 40003)), "drop the token")

        // Anything else is the request's fault, not the credential's, and
        // must not cost the user their token.
        checkEq("code 1 (bad params) -> keep the token", rejectionLabel(envelope(1, "INVALID_PARAM")),
                "keep the token")
        checkEq("code 0 -> no error", rejectionLabel(envelope(0)), "no error")
        checkEq("biz_code 0 -> no error", rejectionLabel(envelope(0, bizCode: 0)), "no error")
        checkEq("HTTP 429 -> keep the token", rejectionLabel(.rateLimited), "keep the token")
        checkEq("HTTP 500 -> keep the token", rejectionLabel(.http(500)), "keep the token")
        checkEq("a 401 still drops it", rejectionLabel(.unauthorized), "drop the token")

        // The server's own message is the only explanation DeepSeek offers, so
        // it has to survive into what the user reads.
        let described = envelope(40003, "Authorization Failed")?.localizedDescription ?? ""
        check("the code is named", described.contains("40003"))
        check("server message reaches the user", described.contains("Authorization Failed"))
        check("the remedy is stated", described.contains("fresh one"))

        // The outer code wins, because a rejected credential arrives with
        // `data: null` and leaves nothing inside to read.
        checkEq("outer code wins over biz_code",
                rejectionLabel(envelope(1, "INVALID_PARAM", bizCode: 40003)), "keep the token")

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
