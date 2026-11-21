import Foundation

/// What the menu bar renders beside the peak/off-peak dot.
///
/// Declaration order is display order, so the joined string reads the same way
/// in the popover's checkboxes and in the menu bar itself.
enum MenuBarItem: String, CaseIterable, Identifiable {
    case balance
    case countdown
    case spentToday

    var id: String { rawValue }

    /// Short enough to sit three-to-a-row in a 340pt popover.
    var label: String {
        switch self {
        case .balance: return "Balance"
        case .countdown: return "Time left"
        case .spentToday: return "Spent today"
        }
    }

    var help: String {
        switch self {
        case .balance:
            return "Total remaining balance — topped up plus granted."
        case .countdown:
            return "Hours until the current peak or off-peak period ends."
        case .spentToday:
            return "Today's spend across every model, as reported by DeepSeek."
        }
    }

    static let separator = " · "

    /// Joins the selected items' rendered values, in declaration order.
    ///
    /// An item with no value is dropped rather than rendered as a dash: a
    /// missing figure almost always means a missing credential, and a menu bar
    /// is the wrong place to explain that. Selecting *nothing* is a deliberate
    /// choice to show the dot alone, so it returns `""` rather than falling
    /// back. But a non-empty selection that produced no values falls back to
    /// the countdown, which is clock arithmetic and therefore the one value
    /// that cannot be unavailable.
    static func compose(
        selected: Set<MenuBarItem>,
        values: [MenuBarItem: String],
        fallback: String
    ) -> String {
        let ordered = allCases.filter(selected.contains)
        guard !ordered.isEmpty else { return "" }
        let parts = ordered.compactMap { values[$0] }
        return parts.isEmpty ? fallback : parts.joined(separator: separator)
    }

    // MARK: - Persistence

    static let defaultsKey = "menuBarItems"
    /// Superseded by `defaultsKey`, which allows any combination. Read once so
    /// an existing choice survives the upgrade.
    private static let legacyBalanceKey = "showBalanceInMenuBar"

    /// Declaration order, so what is written to disk does not depend on how a
    /// Set happened to hash.
    static func encode(_ items: Set<MenuBarItem>) -> [String] {
        allCases.filter(items.contains).map(\.rawValue)
    }

    /// `defaults` is a parameter rather than a direct `.standard` reference so
    /// the migration can be tested against a throwaway suite.
    static func load(from defaults: UserDefaults = .standard) -> Set<MenuBarItem> {
        if let stored = defaults.array(forKey: defaultsKey) as? [String] {
            let parsed = Set(stored.compactMap(MenuBarItem.init(rawValue:)))
            // A non-empty stored set that parsed to nothing means the values
            // came from a newer version, so fall through to the default rather
            // than silently blanking the bar.
            if !parsed.isEmpty || stored.isEmpty { return parsed }
        }
        if defaults.object(forKey: legacyBalanceKey) != nil {
            let showedBalance = defaults.bool(forKey: legacyBalanceKey)
            defaults.removeObject(forKey: legacyBalanceKey)
            // The old toggle was either/or: balance *replaced* the countdown.
            return showedBalance ? [.balance] : [.countdown]
        }
        return [.countdown]
    }
}
