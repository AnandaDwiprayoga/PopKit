import Foundation

/// What to do when an app won't say whether the selection is in an editable field. Slack, for one,
/// refuses every accessibility query from other apps, so PopKit can read its selection (by pressing
/// ⌘C) but can't tell a message box from read-only text.
public final class FieldRules {
    private static let key = "popkit.assumeEditableWhenUnknown"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True (the default) shows the rewrite buttons in such apps. They then also appear on read-only
    /// text there, where pasting does nothing. False hides them, so only actions that don't paste show.
    public var assumeEditableWhenUnknown: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
