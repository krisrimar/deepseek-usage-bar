import Foundation

/// The parts of "is there a newer release, and where is it?" that can be
/// decided without a network or a window, so they can be tested directly.
///
/// The release layout is deliberately version-free in the asset names: the tag
/// carries the version, so `install.sh` and the in-app updater can both ask
/// `releases/latest/download/<name>` for a name that never changes as versions
/// come out.
enum UpdateCheck {
    static let repository = "krisrimar/deepseek-usage-bar"

    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!

    static let zipAsset = "DeepSeekUsageBar-macos-universal.zip"
    static let checksumAsset = zipAsset + ".sha256"
    static let dmgAsset = "DeepSeekUsageBar-macos-universal.dmg"

    /// The bundle's file name. The executable inside is still
    /// `DeepSeekUsageBar`; this is the name Finder, /Applications and the
    /// installer use. Kept here so the updater and the release scripts cannot
    /// drift apart.
    static let appBundle = "DeepSeek Usage Bar.app"

    /// A release as the updater needs it: what it is called, where its notes
    /// live, and the two downloads it is allowed to make.
    struct Release: Equatable {
        var version: String
        var notes: String
        var pageURL: URL?
        var zipURL: URL?
        var checksumURL: URL?
        var dmgURL: URL?
    }

    enum ParseError: Error, LocalizedError {
        case unreadable
        case badTag(String)
        case missingAsset(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "GitHub sent a release description this app did not understand."
            case .badTag(let tag):
                return "The latest release has a tag that is not a version: \(tag)."
            case .missingAsset(let name):
                return "The latest release has no \(name) download."
            }
        }
    }

    /// `v0.5.0` and `0.5.0` are the same version; the `v` is a tag convention,
    /// not part of the number.
    static func version(fromTag tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }

    /// Numeric components of a dotted version, or nil when the string is not
    /// one. Pre-release suffixes (`0.5.0-beta.1`) are rejected rather than
    /// silently sorted below the release: this project does not publish them,
    /// and guessing would be worse than refusing.
    static func components(_ version: String) -> [Int]? {
        let text = Self.version(fromTag: version)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }

    /// True when `candidate` is a later version than `current`.
    ///
    /// A development build reports "dev", which has no components; every real
    /// release is newer than it. An unparseable *candidate* is never newer — a
    /// broken tag must not be offered as an upgrade.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate) else { return false }
        guard let old = components(current) else { return true }

        let count = max(new.count, old.count)
        for index in 0..<count {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Reads GitHub's `/releases/latest` response. It points at the stable
    /// asset names above rather than constructing URLs from the tag, so a
    /// renamed tag cannot produce a download link that 404s.
    static func parseRelease(_ data: Data) throws -> Release {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw ParseError.unreadable
        }

        let version = version(fromTag: tag)
        guard components(version) != nil else { throw ParseError.badTag(tag) }

        func assetURL(_ name: String) -> URL? {
            for asset in assets where asset["name"] as? String == name {
                if let raw = asset["browser_download_url"] as? String {
                    return URL(string: raw)
                }
            }
            return nil
        }

        guard let zip = assetURL(zipAsset) else {
            throw ParseError.missingAsset(zipAsset)
        }
        guard let checksum = assetURL(checksumAsset) else {
            throw ParseError.missingAsset(checksumAsset)
        }

        return Release(
            version: version,
            notes: json["body"] as? String ?? "",
            pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)),
            zipURL: zip,
            checksumURL: checksum,
            dmgURL: assetURL(dmgAsset)
        )
    }

    /// The digest is the first token of a `shasum -a 256` file and is checked
    /// for shape here rather than being compared as whatever text arrived.
    static func expectedChecksum(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let token = text.split(whereSeparator: {
                  $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
              }).first else { return nil }

        let hex = String(token).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}
