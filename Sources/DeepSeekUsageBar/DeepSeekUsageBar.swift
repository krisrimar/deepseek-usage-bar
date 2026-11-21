import SwiftUI
import AppKit
import Charts

// MARK: - Colours

extension PeakSchedule.State {
    var color: NSColor {
        // Green reads as "cheap, go ahead", orange as "this costs double".
        self == .offPeak
            ? NSColor(srgbRed: 0.13, green: 0.72, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.55, blue: 0.09, alpha: 1)
    }
    var swiftUIColor: Color { Color(color) }
    var label: String { self == .peak ? "Peak" : "Off-peak" }
}

extension PeakSchedule.OffPeakReason {
    /// The caption under the tier line. The countdown sits beside the tier
    /// already, so this line spends itself on the *why* rather than repeating
    /// how long it lasts.
    var explanation: String {
        switch self {
        case .weekend:
            return "Half price — weekends are off-peak all day, make-up workdays included."
        case .holiday(let name):
            return "Half price — \(name), a Chinese public holiday."
        case .outsidePeakHours:
            return "Half price — a working day, outside both peak windows."
        }
    }

    /// The same answer as a noun phrase, for the places with no room for a
    /// sentence: the menu bar item's tooltip and the diagnostics block.
    var shortReason: String {
        switch self {
        case .weekend:
            return "the weekend"
        case .holiday(let name):
            return "\(name), a public holiday"
        case .outsidePeakHours:
            // Says the day is ordinary and only the clock makes it off-peak,
            // which is the reassurance worth having on a working day.
            return "the hour, not the day"
        }
    }
}

// MARK: - Observable state

@MainActor
final class AppModel: ObservableObject {
    @Published var state: PeakSchedule.State = .offPeak
    /// Why the tier is off-peak, or nil while it is peak. Derived from the tier
    /// rather than stored beside it, so the two cannot disagree.
    @Published var offPeakReason: PeakSchedule.OffPeakReason?
    @Published var nextTransition: Date?
    @Published var balance: Balance?
    @Published var todayUsage: UsageWindow?
    @Published var errorText: String?
    @Published var hasUserToken: Bool = false
    @Published var hasAPIKey: Bool = false
    @Published var isLoading = false

    // Deliberately model-owned rather than view-owned @State/@AppStorage:
    // both of those are macros, and this project compiles with a bare swiftc
    // invocation that cannot load SwiftUI's macro plugin. See app/build.sh.
    @Published var tokenDraft: String = ""
    @Published var apiKeyDraft: String = ""
    /// Briefly true after a copy, so the button can confirm it happened.
    @Published var copiedDiagnostics = false
    @Published var menuBarItems: Set<MenuBarItem> = MenuBarItem.load() {
        didSet {
            UserDefaults.standard.set(MenuBarItem.encode(menuBarItems),
                                      forKey: MenuBarItem.defaultsKey)
        }
    }

    // The spend chart. Loaded separately from `refresh()` because it is a
    // second, wider request to the same endpoint — see `refreshSpend`.
    @Published var spendRange: SpendRange = SpendRange.load() {
        didSet {
            guard spendRange != oldValue else { return }
            spendRange.save()
            // The loaded series belongs to the window that was just replaced.
            // Keeping it on screen under the new heading would mislabel every
            // bar, so it goes and the placeholder stands in until the new one
            // arrives.
            spendSeries = nil
            Task { await refreshSpend(force: true) }
        }
    }
    @Published var spendSeries: SpendSeries?
    @Published var spendError: String?
    @Published var isLoadingSpend = false
    /// When the current series was fetched, so reopening the popover seconds
    /// after closing it does not fetch the same window again.
    private var spendFetchedAt: Date?
    /// When `nextTransition` was last scanned, so a nil answer is not rebuilt
    /// every tick while the next change lies beyond the scan horizon.
    private var nextTransitionScannedAt: Date?

    let client = DeepSeekClient()
    /// Owned by the model so both windows see the same check result, and so it
    /// outlives the Settings window that usually drives it.
    let updater = Updater()

    /// Human countdown to the next state change, e.g. "2h14m".
    var countdown: String {
        guard let next = nextTransition else { return "--" }
        let secs = max(0, Int(next.timeIntervalSinceNow))
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m" : "\(m)m"
    }

    func setMenuBarItem(_ item: MenuBarItem, on: Bool) {
        var items = menuBarItems
        if on { items.insert(item) } else { items.remove(item) }
        // Assigned rather than mutated in place, so the change is published.
        menuBarItems = items
    }

    /// What the menu bar shows beside the dot.
    var menuBarText: String {
        var values: [MenuBarItem: String] = [:]
        if let b = balance { values[.balance] = Pricing.usd(b.total) }
        if nextTransition != nil { values[.countdown] = countdown }
        if let c = todayUsage?.cost {
            values[.spentToday] = (c.estimated ? "≥ " : "") + Pricing.usd(c.amount)
        }
        return MenuBarItem.compose(selected: menuBarItems, values: values, fallback: countdown)
    }

    /// Whether today has any peak window at all. False on a weekend and on a
    /// holiday, when the whole day is off-peak. "Today" is the viewer's local
    /// day, which is the day the clock beside it is about.
    var hasPeakToday: Bool { PeakSchedule.hasPeak(inLocalDayContaining: Date()) }

    /// Today's peak windows, or "none" on a day that has none. Properties of the
    /// model rather than the view because `Copy diagnostics` reports the same
    /// answer, and two copies could drift.
    var peakTodayText: String {
        hasPeakToday ? PeakSchedule.localPeakWindowsText(on: Date()) : "none"
    }

    /// The last year the shipped holiday table knows about, as text.
    var holidayTableThrough: String {
        Holidays.coveredThroughYear.map { String($0) } ?? "an unknown year"
    }

    /// True when the shipped holiday table cannot vouch for today, or for the
    /// days the countdown looks ahead to.
    ///
    /// The tier is still computed the usual way. A stale table only ever lacks
    /// holiday *exclusions*, so it can read "peak" during a real holiday and
    /// never the reverse — guessing off-peak would understate cost, which is
    /// the worse error.
    var holidayTableStale: Bool {
        Holidays.isStale(Date(), lookaheadDays: PeakSchedule.transitionScanDays)
    }

    /// One line, shared by the popover and the diagnostics block.
    var holidayTableNote: String {
        "Holiday dates end with \(holidayTableThrough) — a later holiday may show as peak."
    }

    func loadCredentials() {
        // Repair a token stored before normalisation existed, so an already
        // saved percent-encoded value starts working without a re-paste.
        if let stored = Keychain.get(Keychain.userTokenAccount), !stored.isEmpty {
            let repaired = DeepSeekClient.normalizeToken(stored)
            if repaired != stored { _ = Keychain.set(repaired, for: Keychain.userTokenAccount) }
        }
        hasUserToken = !(Keychain.get(Keychain.userTokenAccount) ?? "").isEmpty
        hasAPIKey = !Self.storedAPIKey().isEmpty
    }

    /// The balance endpoint needs the `sk-` key, and the only copy the app will
    /// use is the one entered in the popover and kept in the Keychain.
    ///
    /// Deliberately not read from `$DEEPSEEK_API_KEY` or from another tool's
    /// configuration: a credential the app never asked for is one the user did
    /// not choose to give it, and silently spending someone else's key makes
    /// the balance shown here hard to account for.
    static func storedAPIKey() -> String {
        Keychain.get(Keychain.apiKeyAccount) ?? ""
    }

    func setAPIKey(_ key: String) {
        let trimmed = DeepSeekClient.normalizeToken(key)
        if trimmed.isEmpty {
            _ = Keychain.delete(Keychain.apiKeyAccount)
        } else {
            _ = Keychain.set(trimmed, for: Keychain.apiKeyAccount)
        }
        loadCredentials()
    }

    /// Reads the key straight off the clipboard and saves it, for the same
    /// reason as `pasteTokenFromClipboard`: a long value in a SecureField is
    /// unreadable once pasted.
    @discardableResult
    func pasteAPIKeyFromClipboard() -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return false }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        setAPIKey(key)
        return true
    }

    /// Masked confirmation that a key is stored, e.g. "••••••••4f2a".
    var apiKeyPreview: String {
        guard let k = Keychain.get(Keychain.apiKeyAccount), k.count > 4 else { return "" }
        return String(repeating: "•", count: 8) + k.suffix(4)
    }

    func setUserToken(_ token: String) {
        let trimmed = DeepSeekClient.normalizeToken(token)
        let previous = Keychain.get(Keychain.userTokenAccount) ?? ""
        if trimmed.isEmpty {
            _ = Keychain.delete(Keychain.userTokenAccount)
        } else {
            _ = Keychain.set(trimmed, for: Keychain.userTokenAccount)
        }
        if trimmed != previous {
            // Everything fetched with the old credential belongs to it. Left
            // in place, a rejected token would freeze "Today by model" at the
            // last reply forever, because a refresh with no token never runs.
            todayUsage = nil
            spendSeries = nil
            spendError = nil
        }
        loadCredentials()
    }

    /// Reads the token straight off the clipboard and saves it.
    ///
    /// Deliberately bypasses the text field: pasting a long JWT into a
    /// SecureField and confirming it is awkward anyway, since every character
    /// renders as a dot.
    @discardableResult
    func pasteTokenFromClipboard() -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return false }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        setUserToken(token)
        return true
    }

    /// Masked confirmation that a token is stored, e.g. "••••••••938e".
    var tokenPreview: String {
        guard let t = Keychain.get(Keychain.userTokenAccount), t.count > 4 else { return "" }
        return String(repeating: "•", count: 8) + t.suffix(4)
    }

    /// Everything needed to diagnose a failure, in one paste-able block.
    ///
    /// Deliberately never includes the token itself — only its length and last
    /// four characters, which is enough to tell two tokens apart and useless
    /// to anyone who intercepts it.
    var diagnosticReport: String {
        var lines: [String] = ["DeepSeek Usage Bar — diagnostics"]

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        lines.append("time:       \(f.string(from: Date()))")
        lines.append("version:    \(Version.display)")
        lines.append("state:      \(state.label)"
                   + (nextTransition.map { _ in " (changes in \(countdown))" } ?? ""))
        // Only off-peak has a reason to give: peak is the windows applying, which
        // the line below already spells out.
        if let reason = offPeakReason {
            lines.append("reason:     because of \(reason.shortReason)")
        }
        lines.append("peak today: \(peakTodayText)")
        // Reported even when healthy: a pasted block should say which table the
        // build carries, the same way it reports the version.
        lines.append(holidayTableStale
                     ? "holidays:   stale — ends \(holidayTableThrough), later holidays read as peak"
                     : "holidays:   covered through \(holidayTableThrough)")
        lines.append("balance:    \(balance.map { Pricing.usd($0.total) } ?? "unavailable")")

        if let token = Keychain.get(Keychain.userTokenAccount) {
            lines.append("token:      ...\(token.suffix(4)) (\(token.count) chars)")
        } else {
            lines.append("token:      none stored")
        }
        lines.append("api key:    "
                     + (hasAPIKey ? "stored" : "none stored"))

        if let window = todayUsage {
            lines.append("bucket:     \(window.bucketSeconds)s")
            lines.append("models:     \(window.models.map(\.model).joined(separator: ", "))")
        }
        if let series = spendSeries {
            let total = (series.total.estimated ? "≥ " : "") + Pricing.usd(series.total.amount)
            lines.append("spend:      \(spendRange.label) — \(series.days.count) days, \(total)")
        }
        if let error = errorText {
            lines.append("error:      \(error)")
        }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticReport, forType: .string)
        copiedDiagnostics = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedDiagnostics = false
        }
    }

    func tick() {
        // One clock reading for all three: separate readings could straddle a
        // transition and leave the tier disagreeing with its own explanation.
        let now = Date()
        state = PeakSchedule.state(at: now)
        offPeakReason = PeakSchedule.offPeakReason(at: now)

        // The schedule is fixed, so a cached transition stays right until it
        // arrives; re-running the minute-by-minute scan every second used to
        // walk thousands of holiday lookups on the main thread during a
        // holiday. A scan that found nothing — the run was longer than
        // `transitionScanDays` — is retried once a minute, not on every tick.
        if let next = nextTransition, next > now { return }
        if nextTransition == nil, let scannedAt = nextTransitionScannedAt,
           now.timeIntervalSince(scannedAt) < 60 { return }
        nextTransition = PeakSchedule.nextTransition(after: now)
        nextTransitionScannedAt = now
    }

    func refresh() async {
        tick()
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let apiKey = Self.storedAPIKey()
        var problems: [String] = []

        if !apiKey.isEmpty {
            do { balance = try await client.fetchBalance(apiKey: apiKey) }
            catch {
                // A 401 here is the sk- key, not the platform token the usage
                // endpoint takes. Name the right credential, drop it so the app
                // stops re-sending a dead value every five minutes, and clear
                // the figure it used to authenticate.
                if let ds = error as? DeepSeekError, ds.isTokenRejection {
                    setAPIKey("")
                    balance = nil
                    problems.append("Balance: API key rejected (401/403). "
                        + "It may have been rotated — paste a fresh one in Settings.")
                } else {
                    problems.append("Balance: \(error.localizedDescription)")
                }
            }
        } else {
            // No key means no figure to show: keeping the last one under a
            // "No API key found" caption would attribute an old key's balance
            // to a credential the app no longer has.
            balance = nil
            problems.append("No API key found — balance unavailable.")
        }

        if let token = Keychain.get(Keychain.userTokenAccount), !token.isEmpty {
            // Local midnight-to-midnight is what "today" means, and asking for
            // exactly one day is what makes the API return hourly buckets
            // instead of daily ones, which is what the peak/off-peak split
            // depends on. The client adjusts the request when that day is
            // 23 or 25 hours long — see `DeepSeekClient.serverWindow`.
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            do { todayUsage = try await client.fetchUsage(userToken: token, from: today, to: tomorrow) }
            catch {
                problems.append("Usage: \(error.localizedDescription)")
                // Drop a refused token rather than re-sending it every five
                // minutes. A dead one cannot be revived and there is no way to
                // mint a replacement programmatically, so re-pasting is the
                // only recovery — and the empty state is what asks for it.
                // `setUserToken` also refreshes `hasUserToken` off the Keychain.
                if let ds = error as? DeepSeekError, ds.isTokenRejection {
                    setUserToken("")
                }
            }
        }

        errorText = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// Loads the popover chart's window.
    ///
    /// Deliberately not folded into `refresh()`: that runs every five minutes
    /// whether or not anyone is looking, while the chart is worth two calls
    /// only while the popover is open. `force` skips the freshness check, which
    /// is what a change of range needs — the window itself has moved, so the
    /// cached series is not a cache hit but a wrong answer.
    func refreshSpend(force: Bool = false) async {
        if !force, let at = spendFetchedAt, Date().timeIntervalSince(at) < 60 { return }

        guard let token = Keychain.get(Keychain.userTokenAccount), !token.isEmpty else {
            spendSeries = nil
            spendError = nil
            return
        }

        // The window is captured rather than read again on the way back: a
        // reply is only good for the range that asked for it.
        let requested = spendRange
        let (start, end) = requested.window()

        isLoadingSpend = true
        defer { isLoadingSpend = false }

        do {
            let series = try await client.fetchSpendSeries(userToken: token, from: start, to: end)
            // Switching range mid-flight clears the chart and starts another
            // fetch. Letting this one land would draw the old window under the
            // new heading, which is worse than showing nothing for a moment.
            guard requested == spendRange else { return }
            spendSeries = series
            spendFetchedAt = Date()
            spendError = nil
        } catch {
            guard requested == spendRange else { return }
            // Same treatment as the one-day call, but the error is not added to
            // `errorText`: a retired token fails both requests, and reporting it
            // twice in two different sections reads as two separate problems.
            // Reported after the token is dropped, because clearing a token
            // also clears the series and any error belonging to the old one.
            if let ds = error as? DeepSeekError, ds.isTokenRejection { setUserToken("") }
            spendError = error.localizedDescription
        }
    }
}

// MARK: - App bootstrap

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: menu bar only, no Dock icon, no app switcher entry.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var clockTimer: Timer?
    private var refreshTimer: Timer?
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?

    /// An .accessory app has no menu bar of its own, but it still needs a main
    /// menu for standard key equivalents to resolve. Without an Edit menu,
    /// ⌘V has nothing to bind to and the token field silently refuses to
    /// paste — which is exactly what the reference app worked around with a
    /// custom NSTextView. Installing the menu is the smaller fix and it makes
    /// ⌘C, ⌘X and ⌘A work too.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsageView(
                model: model,
                updater: model.updater,
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        popover.contentSize = Self.popoverSize()

        model.loadCredentials()
        updateMenuBar()

        // Silent, at most once a day. A failure leaves the app alone; a hit
        // puts the update badge in the popover header.
        Task { @MainActor in await model.updater.checkIfDue() }

        // The clock drives the dot and the countdown and needs no network, so
        // it keeps running at full rate even when the API calls are failing.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMenuBar() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.model.refresh()
                // The chart is a second, wider call to the same endpoint. It is
                // only worth making while the popover is actually open, and the
                // freshness guard inside stops it repeating on a quick reopen.
                if self?.popover.isShown == true { await self?.model.refreshSpend() }
                self?.updateMenuBar()
            }
        }
        Task { @MainActor in
            await model.refresh()
            updateMenuBar()
        }
    }

    private func updateMenuBar() {
        model.tick()
        guard let button = statusItem.button else { return }
        button.image = Self.dotImage(color: model.state.color)
        // The leading space is the gap from the dot, so it must not be added
        // when everything is switched off and the dot stands alone.
        let text = model.menuBarText
        button.title = text.isEmpty ? "" : " " + text
        var tip = "DeepSeek \(model.state.label)"
        if let reason = model.offPeakReason { tip += " — because of \(reason.shortReason)" }
        if model.nextTransition != nil { tip += " — changes in \(model.countdown)" }
        button.toolTip = tip
    }

    /// The popover is anchored to the status item, and AppKit will happily let
    /// it grow taller than the display — which pushes its top edge off-screen.
    /// Cap it against the visible frame so it always fits, and let the content
    /// scroll instead.
    private static func popoverSize() -> NSSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let available = (screen?.visibleFrame.height ?? 800) - 40
        return NSSize(width: UsageView.width, height: min(560, max(220, available)))
    }

    /// A filled circle, tinted. Drawn rather than built from an SF Symbol so
    /// the colour survives the menu bar's template rendering.
    private static func dotImage(color: NSColor, size: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func handleClick() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
        Task { @MainActor in await model.refresh() }
        Task { @MainActor in await model.refreshSpend() }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Opens the settings window, or brings it forward if it is already up.
    ///
    /// An .accessory app has no Dock icon and no app menu of its own, so the
    /// gear in the popover header is the only way in. The window is built once
    /// and kept, which also preserves a half-typed credential if it is closed
    /// and reopened.
    private func openSettings() {
        closePopover()

        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: SettingsView(
                model: model, updater: model.updater
            ))
            window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Popover UI

struct UsageView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        // ScrollView so the content can never dictate a height taller than
        // the space the popover was given. Without it the popover sizes to
        // its intrinsic height and runs off the top of the display.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                stateSection
                Divider()
                balanceSection
                Divider()
                spendSection
                Divider()
                usageSection
                if let error = model.errorText {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Error").font(.caption).bold()
                            Spacer()
                            Button(model.copiedDiagnostics ? "Copied" : "Copy") {
                                model.copyDiagnostics()
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                        // Selectable as well as copyable, so a partial value
                        // (just the code, say) can be grabbed directly.
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                footer
            }
            .padding(14)
            .frame(width: Self.width, alignment: .leading)
        }
        .frame(width: Self.width)
    }

    static let width: CGFloat = 340

    /// Where the ☕ in the footer points.
    private static let coffeeURL = URL(string: "https://buymeacoffee.com/krisrimar")!

    private var header: some View {
        HStack(spacing: 6) {
            Text("DeepSeek").font(.headline)
            // Selectable so it can be quoted into a bug report; the diagnostics
            // block carries it too, but this is the version at a glance.
            Text(Version.display)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .help("Version \(Version.display) — see CHANGELOG.md for what changed.")
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            if updater.availableRelease != nil {
                Button(action: onOpenSettings) {
                    Image(systemName: "arrow.down.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("An update is available — open Settings to install it.")
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings — menu bar items, API key and platform token")
        }
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.state.swiftUIColor)
                    .frame(width: 11, height: 11)
                    .help(model.state == .peak
                          ? "Peak — full rate. Peak runs \(peakHoursHint) on weekdays."
                          : "Off-peak — half rate, because of "
                            + (model.offPeakReason?.shortReason ?? "the clock")
                            + ". Peak resumes in \(model.countdown).")
                Text(model.state == .peak ? "Peak rates" : "Off-peak rates")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(model.countdown)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // Hidden by opacity rather than dropped by an `if`, matching the
            // line below: both belong to the tier, and one is always blank.
            Text(model.offPeakReason?.explanation ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(model.state == .offPeak ? 1 : 0)
            Text("Double price. Off-peak resumes in \(model.countdown).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(model.state == .peak ? 1 : 0)
            if model.holidayTableStale {
                Text(model.holidayTableNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("The Chinese public holiday table ships with the app and is "
                        + "refreshed by hand from the State Council's annual notice, "
                        + "usually published each November. Until this build is updated, "
                        + "a holiday after \(model.holidayTableThrough) is treated as a "
                        + "working day, so the tier above can read Peak when it is really "
                        + "off-peak. The tier is not guessed downward on purpose.")
            }
            // A weekend or a holiday has no peak window at all, so listing the
            // clock's two would contradict the line above it.
            HStack(spacing: 4) {
                Text("Peak today:")
                Text(model.peakTodayText)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(model.hasPeakToday
                  ? "The two windows peak applies in, in your own timezone."
                  : "No peak window applies today — the whole day is off-peak.")
        }
    }

    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Balance").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(model.balance.map { Pricing.usd($0.total) } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            if let b = model.balance {
                Text("topped up \(Pricing.usd(b.toppedUp)) · granted \(Pricing.usd(b.granted))")
                    .font(.caption).foregroundStyle(.secondary)
                if !b.isAvailable {
                    Text("Balance is not usable for API calls.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if !model.hasAPIKey {
                Text("No API key found — add one in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var spendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Spend").font(.system(size: 13, weight: .medium))
                Spacer()
                if model.isLoadingSpend, model.spendSeries == nil {
                    ProgressView().controlSize(.small)
                }
                if let series = model.spendSeries {
                    Text((series.total.estimated ? "≥ " : "") + Pricing.usd(series.total.amount))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .help(series.total.estimated
                              ? "Total for the window. DeepSeek did not report a cost for every model, so part of this is worked out from the rate table at off-peak rates — the real figure is at least this much."
                              : "Total spend for the window, as reported by DeepSeek.")
                }
            }

            Picker("", selection: $model.spendRange) {
                ForEach(SpendRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Segmented controls size to their widest label and sit inset from
            // the edges; the chart below spans the full width, and a selector
            // narrower than the thing it selects for looks like a mistake.
            .frame(maxWidth: .infinity)
            .help("How far back the chart looks. All three end with today.")

            // Shown above the chart rather than instead of it: a refresh that
            // fails leaves the last good series in place, exactly as the
            // balance does, so the error has to be able to appear alongside it.
            if let error = model.spendError {
                Text(error)
                    .font(.caption2).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let series = model.spendSeries {
                // A window with no spend at all gets a line rather than a chart:
                // bars of zero height on an axis scaled to nothing carry no
                // information, and its tick labels all round to the same figure.
                if series.isEmpty {
                    Text("No spend recorded in this window.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SpendChart(series: series)
                }
            } else if model.spendError == nil {
                Text(model.hasUserToken
                     ? (model.isLoadingSpend ? "Loading…" : "No spend recorded in this window.")
                     : "Paste a platform token in Settings to see spend over time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today by model").font(.system(size: 13, weight: .medium))
                Spacer()
                if let c = model.todayUsage?.cost {
                    // The same figure the menu bar can show, so the two are
                    // checkable against each other.
                    Text((c.estimated ? "≥ " : "") + Pricing.usd(c.amount))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .help(c.estimated
                              ? "DeepSeek did not report a cost for every model, so some of this is worked out from the rate table at off-peak rates — the real figure is at least this much."
                              : "Today's total across every model, as reported by DeepSeek.")
                }
                if let w = model.todayUsage {
                    Text(w.isHourly ? "hourly" : "daily")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help(w.isHourly
                              ? "Hourly data, so peak and off-peak can be told apart exactly."
                              : "This window came back as daily totals. A day spans both rate tiers, so no peak/off-peak split is shown.")
                }
            }
            if let window = model.todayUsage, !window.models.isEmpty {
                if let totals = tieredTotals(window) {
                    Text(totals)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Spend so far today, split by rate tier. Off-peak is exactly half price, so \"saved\" is what the peak-half of your traffic would have cost extra during peak hours.")
                }
                ForEach(window.models) { row($0) }
            } else {
                Text(model.hasUserToken
                     ? "No usage recorded yet today."
                     : "Paste a platform token in Settings to see per-model usage.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Peak windows in the user's own timezone, for tooltips.
    private var peakHoursHint: String {
        PeakSchedule.localPeakWindowsText(on: Date())
    }

    /// Peak and off-peak spend across every model, when the window came back
    /// hourly. This is the number the app exists to produce: the same traffic
    /// costs exactly twice as much in a peak hour.
    private func tieredTotals(_ window: UsageWindow) -> String? {
        guard window.isHourly else { return nil }
        let peak = window.models.compactMap(\.peakCost).reduce(Decimal.zero, +)
        let offPeak = window.models.compactMap(\.offPeakCost).reduce(Decimal.zero, +)
        guard peak > 0 || offPeak > 0 else { return nil }
        let saved = peak / 2   // what the peak half would have cost at off-peak
        return "peak \(Pricing.usd(peak)) · off-peak \(Pricing.usd(offPeak))"
             + " · saved \(Pricing.usd(saved))"
    }

    private func row(_ usage: ModelUsage) -> some View {
        // DeepSeek reports the actual cost, which is authoritative. Only fall
        // back to arithmetic if that endpoint came back empty.
        let computed = Pricing.rates(for: usage.model).map {
            Pricing.cost(cacheHitTokens: usage.cacheHitTokens,
                         cacheMissTokens: usage.cacheMissTokens,
                         outputTokens: usage.outputTokens,
                         rates: $0, isPeak: false)
        }
        let cost = usage.cost.map { Pricing.usd($0) }
            ?? computed.map { "≥ " + Pricing.usd($0) } ?? "—"

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(usage.model).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(cost).font(.system(size: 12, design: .monospaced))
            }
            Text("\(usage.requests) req · \(compact(usage.totalTokens)) tk · hit \(compact(usage.cacheHitTokens)) · miss \(compact(usage.cacheMissTokens)) · out \(compact(usage.outputTokens))")
                .font(.caption2).foregroundStyle(.secondary)
            if usage.tiered, usage.peakTokens > 0 || usage.offPeakTokens > 0 {
                HStack(spacing: 5) {
                    Circle().fill(PeakSchedule.State.peak.swiftUIColor)
                        .frame(width: 6, height: 6)
                        .help("Peak hours — billed at full rate")
                    Text("peak \(compact(usage.peakTokens))")
                        .help("Tokens sent during peak hours, billed at full rate (\(peakHoursHint))")
                    Circle().fill(PeakSchedule.State.offPeak.swiftUIColor)
                        .frame(width: 6, height: 6)
                        .help("Off-peak — billed at half rate")
                    Text("off-peak \(compact(usage.offPeakTokens))")
                        .help("Tokens sent off-peak, billed at half the peak rate")
                    Spacer()
                    if let p = usage.peakCost {
                        Text("peak cost \(Pricing.usd(p))")
                            .foregroundStyle(.secondary)
                            .help("What this model's peak-hour tokens cost. The off-peak ones cost half what the same tokens would at peak.")
                    }
                }
                .font(.caption2)
            }
        }
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(Self.coffeeURL)
            } label: {
                Text("☕ Buy me a coffee")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.orange)
            .help("Opens buymeacoffee.com/krisrimar in your browser.")
            Spacer()
            // Available with or without an error, since the diagnostics are
            // just as useful when something silently looks wrong.
            Button(model.copiedDiagnostics ? "Copied" : "Copy diagnostics") {
                model.copyDiagnostics()
            }
            .buttonStyle(.link).font(.caption)
            Button("Quit", action: onQuit).buttonStyle(.link).font(.caption)
        }
    }
}

// MARK: - Spend chart

/// One bar per day of the selected window, with a readout underneath that
/// follows the cursor.
///
/// Swift Charts rather than hand-drawn bars: it brings the axes, the gridlines
/// and the scaling for free, and it links against this SDK with nothing more
/// than `-framework Charts` in `build.sh`.
private struct SpendChart: View {
    let series: SpendSeries

    /// Hover is tracked by an `ObservableObject` rather than `@State`, which is
    /// a macro this toolchain cannot expand. `@StateObject` is an ordinary
    /// property wrapper and works. See `app/build.sh`.
    final class Hover: ObservableObject {
        @Published var day: DailySpend?
    }
    @StateObject private var hover = Hover()

    /// Weekday for a week, a date for a month: across 30 bars the weekday
    /// repeats four times over and tells you nothing.
    private let axisDay: DateFormatter
    private let readoutDay: DateFormatter

    init(series: SpendSeries) {
        self.series = series
        let axis = DateFormatter()
        axis.setLocalizedDateFormatFromTemplate(series.days.count <= 10 ? "EEE" : "dMMM")
        self.axisDay = axis

        let readout = DateFormatter()
        readout.setLocalizedDateFormatFromTemplate("EEEdMMM")
        self.readoutDay = readout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart(series.days) { entry in
                BarMark(
                    x: .value("Day", entry.day, unit: .day),
                    y: .value("Spend", Self.dollars(entry.cost))
                )
                .foregroundStyle(style(for: entry))
                .cornerRadius(2)
            }
            // Headroom above the busiest day, so the tallest bar sits below the
            // top edge rather than appearing to be cut off by it. The floor
            // keeps an all-but-zero window from collapsing the axis.
            .chartYScale(domain: 0...max(Self.dollars(series.busiestCost) * 1.15, 0.01))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(Self.axisUSD(amount)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisTicks) { value in
                    AxisValueLabel {
                        if let day = value.as(Date.self) { Text(axisDay.string(from: day)) }
                    }
                }
            }
            .frame(height: 92)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                hover.day = day(at: point,
                                                in: geometry[proxy.plotAreaFrame],
                                                proxy: proxy)
                            case .ended:
                                hover.day = nil
                            }
                        }
                }
            }

            Text(readout)
                .font(.caption2)
                .foregroundStyle(hover.day == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The instants that carry an x-axis label — one per chosen bar.
    ///
    /// `AxisMarks` with an automatic count divides the *time domain*, not the
    /// bars, so a one-day window asked for four marks produced four ticks
    /// inside that day and four copies of "Sun". Picking one instant per bar,
    /// at midday so it sits over the bar rather than on its edge, keeps the
    /// labels on distinct days and bounded to about four.
    private var axisTicks: [Date] {
        let days = series.days.map(\.day)
        guard !days.isEmpty else { return [] }
        guard days.count > 4 else {
            return days.map { $0.addingTimeInterval(12 * 3600) }
        }
        let step = max(1, Int((Double(days.count - 1) / 3.0).rounded()))
        var indices = Array(stride(from: 0, to: days.count, by: step))
        if indices.last != days.count - 1 { indices.append(days.count - 1) }
        return indices.map { days[$0].addingTimeInterval(12 * 3600) }
    }

    /// What the line under the chart says: the day under the cursor, or the
    /// window in summary when nothing is hovered.
    private var readout: String {
        if let day = hover.day {
            return "\(readoutDay.string(from: day.day)) · "
                 + (day.estimated ? "≥ " : "") + Pricing.usd(day.cost)
                 + " · \(day.requests) req"
        }
        if series.isEmpty { return "No spend in this window." }

        var parts: [String] = []
        if let busiest = series.busiest {
            parts.append("busiest \(readoutDay.string(from: busiest.day)) · \(Pricing.usd(busiest.cost))")
        }
        parts.append("avg \(Pricing.usd(series.dailyAverage))/day")
        return parts.joined(separator: " · ")
    }

    /// Dim the rest of the chart while a day is hovered, so the bar under the
    /// cursor is unambiguous. Nothing is dimmed when nothing is hovered.
    private func style(for entry: DailySpend) -> Color {
        guard let hovered = hover.day else { return .accentColor }
        return hovered.day == entry.day ? .accentColor : Color.accentColor.opacity(0.3)
    }

    /// The bar under the cursor.
    ///
    /// `value(atX:)` measures from the **plot area**, while the overlay spans
    /// the whole chart — including the y-axis labels down the left. Handing it
    /// the raw cursor position therefore shifts every hit right by the width of
    /// those labels, which is most of a bar on a week and three or four on a
    /// month. `geometry[proxy.plotAreaFrame]` is what reconciles the two.
    private func day(at point: CGPoint, in plot: CGRect, proxy: ChartProxy) -> DailySpend? {
        guard plot.width > 0 else { return nil }
        // Clamped rather than ignored, so a cursor just past either edge still
        // reads the end bar instead of blanking the readout mid-gesture.
        let x = min(max(point.x - plot.origin.x, 0), plot.width)
        return containingDay(at: proxy.value(atX: x, as: Date.self))
    }

    /// The bar containing the cursor's x position.
    ///
    /// Charts reports a continuous date there and each bar spans a whole day,
    /// so the answer is the bar whose day starts at or before the cursor — not
    /// the nearest bar's *start*, which would hand the cursor to tomorrow as
    /// soon as it passed local noon. `days` is built oldest-first.
    private func containingDay(at date: Date?) -> DailySpend? {
        guard let date else { return nil }
        return series.days.last { $0.day <= date } ?? series.days.first
    }

    private static func dollars(_ amount: Decimal) -> Double {
        NSDecimalNumber(decimal: amount).doubleValue
    }

    /// Axis money at a glance: cents matter on a small axis and are noise on a
    /// large one, and a very cheap window needs a third decimal or every tick
    /// rounds to the same figure.
    private static func axisUSD(_ amount: Double) -> String {
        if amount == 0 { return "$0" }
        if amount < 0.1 { return String(format: "$%.3f", amount) }
        if amount < 1 { return String(format: "$%.2f", amount) }
        if amount < 100 { return String(format: "$%.1f", amount) }
        return String(format: "$%.0f", amount)
    }
}
