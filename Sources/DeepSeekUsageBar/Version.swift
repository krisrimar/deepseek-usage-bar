import Foundation

/// Which build is running, read from the bundle's own `Info.plist`.
///
/// The plist is the single source of truth rather than a Swift constant: it is
/// what the `.app` carries, what Finder's Get Info shows, and what would go
/// into a release. Copying the number into the source would make two things to
/// bump and guarantee they eventually disagree.
///
/// Outside an `.app` — running the bare `app/build/DeepSeekUsageBar`, or the
/// test binaries, neither of which has an Info.plist — every lookup fails and
/// the version degrades to "dev" rather than to something that looks real.
enum Version {
    /// Marketing version, e.g. "0.2.0".
    static let short: String = info("CFBundleShortVersionString") ?? "dev"

    /// Build number, e.g. "2". Empty outside a bundle.
    static let build: String = info("CFBundleVersion") ?? ""

    /// "0.2.0 (2)", or bare "dev" when there is no bundle to ask.
    static var display: String {
        build.isEmpty ? short : "\(short) (\(build))"
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
