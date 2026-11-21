import Foundation
import AppKit
import CryptoKit

/// Checks GitHub for a newer release and, when asked, replaces the running
/// app with it.
///
/// There is deliberately no silent install: a check may happen on its own, but
/// the user clicks **Install** before anything is downloaded and swapped. The
/// download is verified twice before it is trusted — against the release's
/// SHA-256, and against the bundle identifier and version inside it.
///
/// The swap is done by a short shell script that waits for this process to
/// exit, stages the new bundle beside the old one, moves it into place and
/// relaunches. Replacing a running bundle directly is the part macOS makes
/// awkward; letting the process end first is what Sparkle does too.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateCheck.Release)
        case downloading
        case readyToInstall
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Persisted by hand rather than with `@AppStorage`, which is a macro this
    /// project's bare `swiftc` build cannot load. See app/build.sh.
    @Published var automaticallyChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecks, forKey: Self.automaticKey)
        }
    }

    private static let automaticKey = "automaticallyChecksForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var installTask: Task<Void, Never>?

    init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    var availableRelease: UpdateCheck.Release? {
        if case .available(let release) = phase { return release }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .readyToInstall, .installing: return true
        default: return false
        }
    }

    private var userAgent: String {
        "DeepSeekUsageBar/\(Version.short) (macOS)"
    }

    // MARK: - Checking

    /// The launch-time check, at most once a day. Failures stay silent: a
    /// menu bar app has no business opening with a network error because
    /// GitHub was briefly unreachable.
    func checkIfDue() async {
        guard automaticallyChecks else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        await check(silent: true)
    }

    func check(silent: Bool = false) async {
        guard !isBusy else { return }
        let previous = phase
        phase = .checking

        do {
            var request = URLRequest(url: UpdateCheck.latestReleaseURL)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdaterError.http(0)
            }
            guard http.statusCode == 200 else {
                throw UpdaterError.http(http.statusCode)
            }

            let release = try UpdateCheck.parseRelease(data)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

            if UpdateCheck.isNewer(release.version, than: Version.short) {
                phase = .available(release)
            } else {
                phase = .upToDate
            }
        } catch {
            // An automatic check that fails leaves the previous phase alone, so
            // a known available update is not erased by a later check failing.
            if silent {
                phase = previous
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Installing

    func install(_ release: UpdateCheck.Release) {
        guard availableRelease != nil, installTask == nil else { return }
        phase = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            await self.performInstall(release)
            self.installTask = nil
        }
    }

    private func performInstall(_ release: UpdateCheck.Release) async {
        do {
            guard let zipURL = release.zipURL else {
                throw UpdaterError.missingAssets
            }
            guard let checksumURL = release.checksumURL else {
                throw UpdaterError.missingAssets
            }

            let destination = Bundle.main.bundleURL
            guard destination.pathExtension == "app" else {
                throw UpdaterError.notAnApplication
            }
            if destination.path.contains("/AppTranslocation/") {
                throw UpdaterError.translocated
            }
            guard FileManager.default.isWritableFile(
                atPath: destination.deletingLastPathComponent().path
            ) else {
                throw UpdaterError.notWritable(destination.deletingLastPathComponent().path)
            }

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeepSeekUsageBar-update-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let zip = work.appendingPathComponent("update.zip")
            let checksumFile = work.appendingPathComponent("update.sha256")

            try await download(zipURL, to: zip)
            try await download(checksumURL, to: checksumFile)

            guard let expected = UpdateCheck.expectedChecksum(
                try Data(contentsOf: checksumFile)
            ) else {
                throw UpdaterError.badChecksumFile
            }
            let actual = try Self.sha256Hex(of: zip)
            guard actual == expected else {
                throw UpdaterError.checksumMismatch
            }

            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

            let newApp = unpacked.appendingPathComponent("DeepSeekUsageBar.app")
            try validate(newApp, expecting: release.version)

            phase = .readyToInstall
            try scheduleReplacement(from: newApp, to: destination)
            phase = .installing

            // Give the script a moment to start waiting on this PID before the
            // process it is waiting for disappears.
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.http(0)
        }
        guard http.statusCode == 200 else {
            throw UpdaterError.http(http.statusCode)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// The checksum proves the bytes are the ones the release published, but
    /// not that the archive contains the app it claims to. This reads the
    /// unpacked bundle's own plist, so a zip built for something else — or a
    /// mismatched asset name — cannot overwrite this app.
    private func validate(_ app: URL, expecting version: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let info = object as? [String: Any],
              let identifier = Bundle.main.bundleIdentifier,
              info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleShortVersionString"] as? String == version,
              FileManager.default.isExecutableFile(
                  atPath: app.appendingPathComponent("Contents/MacOS/DeepSeekUsageBar").path
              ) else {
            throw UpdaterError.invalidBundle
        }
    }

    private func scheduleReplacement(from newApp: URL, to destination: URL) throws {
        let script = newApp.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("install-update.sh")

        // Absolute paths only: the script has no PATH of its own. The staging
        // directory is a sibling of the destination, so the final `mv` is on
        // the same volume and cannot leave a half-copied app behind.
        let text = """
        #!/bin/sh
        set -eu
        pid="$1"; new="$2"; dest="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -ge 300 ] && exit 1
            sleep 0.1
        done
        staging="${dest}.updating"
        rm -rf "$staging"
        /usr/bin/ditto "$new" "$staging"
        rm -rf "$dest"
        mv "$staging" "$dest"
        /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
        /usr/bin/open "$dest"
        """

        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            newApp.path,
            destination.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdaterError.commandFailed(message ?? "")
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum UpdaterError: Error, LocalizedError {
    case http(Int)
    case missingAssets
    case badChecksumFile
    case checksumMismatch
    case invalidBundle
    case notAnApplication
    case translocated
    case notWritable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .http(let status):
            return status == 0
                ? "GitHub did not answer the update request."
                : "GitHub answered the update request with HTTP \(status)."
        case .missingAssets:
            return "The release does not have the downloads this app needs."
        case .badChecksumFile:
            return "The release's checksum file is not in the expected format."
        case .checksumMismatch:
            return "The download did not match its published checksum, so nothing was installed."
        case .invalidBundle:
            return "The download is not the expected DeepSeek Usage Bar build, so nothing was installed."
        case .notAnApplication:
            return "Updates only work when the app is running from its .app bundle."
        case .translocated:
            return "The app is running from a temporary location. Move it to Applications, relaunch it, and try again."
        case .notWritable(let path):
            return "The app cannot write to \(path). Move DeepSeek Usage Bar to Applications and try again."
        case .commandFailed(let message):
            return message.isEmpty
                ? "A command needed to install the update failed."
                : "Installing the update failed: \(message)"
        }
    }
}
