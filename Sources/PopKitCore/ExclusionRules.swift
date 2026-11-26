import Foundation

/// Decides whether PopKit may look at the frontmost app: a global pause plus a
/// bundle-ID blocklist. Persisted in UserDefaults.
public final class ExclusionRules {
    /// Password managers and system sign-in screens. Secure text fields are
    /// skipped separately, whatever this list says.
    public static let defaultExcluded: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.loginwindow",
    ]

    private enum Key {
        static let paused = "popkit.paused"
        static let excluded = "popkit.excludedBundleIDs"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isPaused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused) }
    }

    /// The user's list, or the defaults until they change it.
    public var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.excluded) ?? Self.defaultExcluded }
        set { defaults.set(newValue, forKey: Key.excluded) }
    }

    public func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// True when the popup must not appear for this app.
    public func shouldSuppress(frontmostBundleID: String?) -> Bool {
        isPaused || isExcluded(frontmostBundleID)
    }

    public func exclude(_ bundleID: String) {
        guard !isExcluded(bundleID) else { return }
        excludedBundleIDs = excludedBundleIDs + [bundleID]
    }

    public func include(_ bundleID: String) {
        excludedBundleIDs = excludedBundleIDs.filter {
            $0.caseInsensitiveCompare(bundleID) != .orderedSame
        }
    }
}
