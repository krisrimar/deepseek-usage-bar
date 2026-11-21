import Foundation

/// Version ordering, release parsing and checksum parsing — the parts of the
/// update path that decide whether to offer a download at all.
///
/// The network and the bundle swap are not exercised here; what is here is the
/// arithmetic that a wrong answer would turn into either a missed update or,
/// worse, an update offered for the version already running.

@main
struct UpdateCheckTests {
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

    static func testVersionNormalisation() {
        print("\nVersion normalisation:")
        checkEq("tag leading v is dropped",
                UpdateCheck.version(fromTag: "v0.5.0"), "0.5.0")
        checkEq("tag leading V is dropped",
                UpdateCheck.version(fromTag: "V1.2.3"), "1.2.3")
        checkEq("an untagged version is unchanged",
                UpdateCheck.version(fromTag: "0.5.0"), "0.5.0")
        checkEq("whitespace is trimmed",
                UpdateCheck.version(fromTag: "  v0.5.0\n"), "0.5.0")
    }

    static func testComponents() {
        print("\nVersion components:")
        checkEq("ordinary dotted version",
                UpdateCheck.components("0.5.0"), [0, 5, 0])
        checkEq("tag form is accepted",
                UpdateCheck.components("v10.2.1"), [10, 2, 1])
        checkEq("two components are allowed",
                UpdateCheck.components("1.2"), [1, 2])
        checkEq("four components are allowed",
                UpdateCheck.components("1.2.3.4"), [1, 2, 3, 4])
        checkEq("pre-release is refused, not mis-sorted",
                UpdateCheck.components("1.2.3-beta.1"), nil)
        checkEq("words are refused",
                UpdateCheck.components("nightly"), nil)
        checkEq("empty is refused",
                UpdateCheck.components(""), nil)
        checkEq("an empty component is refused",
                UpdateCheck.components("1..2"), nil)
        checkEq("a sign is not a digit",
                UpdateCheck.components("+1.2.3"), nil)
    }

    static func testOrdering() {
        print("\nOrdering:")
        checkEq("a later patch is newer",
                UpdateCheck.isNewer("0.5.1", than: "0.5.0"), true)
        checkEq("a later minor is newer",
                UpdateCheck.isNewer("0.6.0", than: "0.5.0"), true)
        checkEq("a later major is newer",
                UpdateCheck.isNewer("1.0.0", than: "0.99.99"), true)
        checkEq("numeric, not lexical, comparison",
                UpdateCheck.isNewer("0.10.0", than: "0.9.9"), true)
        checkEq("the same version is not newer",
                UpdateCheck.isNewer("0.5.0", than: "0.5.0"), false)
        checkEq("a missing component counts as zero",
                UpdateCheck.isNewer("0.5", than: "0.5.0"), false)
        checkEq("a leading v does not matter",
                UpdateCheck.isNewer("v0.5.1", than: "0.5.0"), true)
        checkEq("a dev build is older than any release",
                UpdateCheck.isNewer("0.5.0", than: "dev"), true)
        checkEq("an unparseable release is never offered",
                UpdateCheck.isNewer("nightly", than: "0.5.0"), false)
        checkEq("an older release is not offered over a newer build",
                UpdateCheck.isNewer("0.4.0", than: "0.5.0"), false)
    }

    static func testReleaseParsing() throws {
        print("\nRelease parsing:")
        let assets = """
        [
          {"name": "DeepSeekUsageBar-macos-universal.zip",
           "browser_download_url": "https://example.test/DeepSeekUsageBar-macos-universal.zip"},
          {"name": "DeepSeekUsageBar-macos-universal.zip.sha256",
           "browser_download_url": "https://example.test/DeepSeekUsageBar-macos-universal.zip.sha256"},
          {"name": "DeepSeekUsageBar-macos-universal.dmg",
           "browser_download_url": "https://example.test/DeepSeekUsageBar-macos-universal.dmg"},
          {"name": "install.sh",
           "browser_download_url": "https://example.test/install.sh"}
        ]
        """
        let json = """
        {
          "tag_name": "v0.6.0",
          "body": "What changed.",
          "html_url": "https://example.test/releases/v0.6.0",
          "assets": \(assets)
        }
        """

        let release = try UpdateCheck.parseRelease(Data(json.utf8))
        checkEq("tag is normalised", release.version, "0.6.0")
        checkEq("notes are carried", release.notes, "What changed.")
        checkEq("zip URL is chosen by name", release.zipURL?.absoluteString,
                "https://example.test/DeepSeekUsageBar-macos-universal.zip")
        checkEq("checksum URL is chosen by name", release.checksumURL?.absoluteString,
                "https://example.test/DeepSeekUsageBar-macos-universal.zip.sha256")
        checkEq("dmg URL is chosen by name", release.dmgURL?.absoluteString,
                "https://example.test/DeepSeekUsageBar-macos-universal.dmg")
        checkEq("release page is carried", release.pageURL?.absoluteString,
                "https://example.test/releases/v0.6.0")

        let missing = """
        {"tag_name": "v0.6.0", "body": "", "assets": []}
        """
        do {
            _ = try UpdateCheck.parseRelease(Data(missing.utf8))
            checkEq("missing downloads are refused", "parsed", "thrown")
        } catch {
            checkEq("missing downloads are refused", "thrown", "thrown")
        }

        let badTag = """
        {"tag_name": "nightly", "body": "", "assets": []}
        """
        do {
            _ = try UpdateCheck.parseRelease(Data(badTag.utf8))
            checkEq("a non-version tag is refused", "parsed", "thrown")
        } catch {
            checkEq("a non-version tag is refused", "thrown", "thrown")
        }

        do {
            _ = try UpdateCheck.parseRelease(Data("not json".utf8))
            checkEq("unreadable JSON is refused", "parsed", "thrown")
        } catch {
            checkEq("unreadable JSON is refused", "thrown", "thrown")
        }
    }

    static func testChecksumParsing() {
        print("\nChecksum parsing:")
        let digest = String(repeating: "a1", count: 32)
        checkEq("plain digest",
                UpdateCheck.expectedChecksum(Data("\(digest)\n".utf8)), digest)
        checkEq("shasum output with a filename",
                UpdateCheck.expectedChecksum(Data("\(digest)  DeepSeekUsageBar-macos-universal.zip\n".utf8)),
                digest)
        checkEq("uppercase is normalised",
                UpdateCheck.expectedChecksum(Data(digest.uppercased().utf8)),
                digest)
        checkEq("a short digest is refused",
                UpdateCheck.expectedChecksum(Data("abc123\n".utf8)), nil)
        checkEq("non-hex characters are refused",
                UpdateCheck.expectedChecksum(Data(String(repeating: "z", count: 64).utf8)), nil)
        checkEq("an empty file is refused",
                UpdateCheck.expectedChecksum(Data()), nil)
    }

    static func main() throws {
        testVersionNormalisation()
        testComponents()
        testOrdering()
        try testReleaseParsing()
        testChecksumParsing()

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed == 0 ? 0 : 1)
    }
}
