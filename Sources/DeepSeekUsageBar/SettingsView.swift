import SwiftUI
import AppKit

/// Configuration that is set once and then left alone.
///
/// The popover is for what changes minute to minute — tier, balance, spend and
/// today's usage — so the menu bar checkboxes and the two credentials live here
/// instead. Keeping them out of the popover stops a glanceable panel from
/// growing a form every time the app learns another setting.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    init(model: AppModel, updater: Updater) {
        self.model = model
        self.updater = updater
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            menuBarSection
            Divider()
            apiKeySection
            Divider()
            tokenSection
            Divider()
            updatesSection
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Menu bar").font(.system(size: 13, weight: .medium))
            HStack(spacing: 10) {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(item.label, isOn: binding(for: item))
                        .toggleStyle(.checkbox)
                        .help(item.help)
                }
            }
            .font(.caption)
            Text("Shown beside the dot, in this order. Uncheck all to leave the dot alone.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API key").font(.system(size: 13, weight: .medium))
                Spacer()
                if model.hasAPIKey, !model.apiKeyPreview.isEmpty {
                    Text(model.apiKeyPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        model.setAPIKey("")
                        model.apiKeyDraft = ""
                        Task { await model.refresh() }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            Text("api.deepseek.com → API keys — needed for balance. The platform token below is a different credential.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("sk-…", text: $model.apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveAPIKey() }
                Button("Paste") {
                    if model.pasteAPIKeyFromClipboard() {
                        // The clipboard value is now what is stored; leaving
                        // older text in the field would let a later Save put
                        // it back.
                        model.apiKeyDraft = ""
                        Task { await model.refresh() }
                    }
                }
                Button("Save") { saveAPIKey() }
                    .disabled(model.apiKeyDraft.isEmpty)
            }
            Text("Stored in the macOS Keychain and sent only to api.deepseek.com to read your balance.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Platform token").font(.system(size: 13, weight: .medium))
                Spacer()
                if model.hasUserToken, !model.tokenPreview.isEmpty {
                    Text(model.tokenPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        model.setUserToken("")
                        model.tokenDraft = ""
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            Text("platform.deepseek.com → DevTools → Application → Local Storage → userToken")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("userToken", text: $model.tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                // A dedicated button, because a SecureField in an app with no
                // menu was the thing that would not accept ⌘V.
                Button("Paste") {
                    if model.pasteTokenFromClipboard() {
                        // As above: the field no longer holds the saved value,
                        // so clear it rather than let Save overwrite the paste.
                        model.tokenDraft = ""
                        Task { await model.refresh() }
                    }
                }
                Button("Save") { save() }
                    .disabled(model.tokenDraft.isEmpty)
            }
            Text("Stored in the macOS Keychain. Tokens are session credentials that DeepSeek can retire; when it stops accepting one the app clears it and asks for a fresh paste.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Updates").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Check for Updates") {
                    Task { await updater.check() }
                }
                .disabled(updater.isBusy)
            }
            Text("Version \(Version.display). Checked against GitHub releases; downloads are verified against the published checksum before anything is installed.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            updateStatus

            Toggle("Check automatically once a day", isOn: $updater.automaticallyChecks)
                .toggleStyle(.checkbox)
                .font(.caption)

            if let release = updater.availableRelease {
                HStack(spacing: 8) {
                    Button("Install \(release.version)") { updater.install(release) }
                    if let page = release.pageURL {
                        Button("Release notes") { NSWorkspace.shared.open(page) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.phase {
        case .idle:
            Text("Not checked yet.")
                .font(.caption2).foregroundStyle(.tertiary)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
            }
            .font(.caption2).foregroundStyle(.secondary)
        case .upToDate:
            Label("You're up to date.", systemImage: "checkmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .available(let release):
            Label("Version \(release.version) is available.", systemImage: "arrow.down.circle.fill")
                .font(.caption2).foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Downloading…")
            }
            .font(.caption2).foregroundStyle(.secondary)
        case .readyToInstall, .installing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Installing — the app will relaunch.")
            }
            .font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption2).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for item: MenuBarItem) -> Binding<Bool> {
        Binding(
            get: { model.menuBarItems.contains(item) },
            set: { model.setMenuBarItem(item, on: $0) }
        )
    }

    private func saveAPIKey() {
        model.setAPIKey(model.apiKeyDraft)
        model.apiKeyDraft = ""
        Task { await model.refresh() }
    }

    private func save() {
        model.setUserToken(model.tokenDraft)
        model.tokenDraft = ""
        Task { await model.refresh() }
    }
}
