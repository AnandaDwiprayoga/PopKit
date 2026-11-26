import Foundation

/// Which side of the selection the popup prefers: a global default plus per-app overrides
/// keyed by bundle ID. Persisted in UserDefaults.
public final class PlacementRules {
    private enum Key {
        static let defaultSide = "popkit.placement.default"
        static let overrides = "popkit.placement.overrides"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var defaultSide: PopupSide {
        get { defaults.string(forKey: Key.defaultSide).flatMap(PopupSide.init) ?? .above }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultSide) }
    }

    /// Bundle ID → side, for the apps that differ from the default.
    public var overrides: [String: PopupSide] {
        get {
            let raw = defaults.dictionary(forKey: Key.overrides) as? [String: String] ?? [:]
            return raw.compactMapValues(PopupSide.init)
        }
        set { defaults.set(newValue.mapValues(\.rawValue), forKey: Key.overrides) }
    }

    public func side(for bundleID: String?) -> PopupSide {
        override(for: bundleID) ?? defaultSide
    }

    /// The app's own setting, or nil when it follows the default.
    public func override(for bundleID: String?) -> PopupSide? {
        guard let bundleID else { return nil }
        return overrides.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
    }

    public func setSide(_ side: PopupSide, for bundleID: String) {
        var current = overrides.filter { $0.key.caseInsensitiveCompare(bundleID) != .orderedSame }
        current[bundleID] = side
        overrides = current
    }

    public func removeOverride(for bundleID: String) {
        overrides = overrides.filter { $0.key.caseInsensitiveCompare(bundleID) != .orderedSame }
    }
}
