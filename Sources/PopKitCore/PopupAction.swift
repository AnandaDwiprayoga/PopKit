import Foundation

/// What an action needs from the selection. Same two names PopClip extensions use.
public struct ActionRequirements: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// There is selected text.
    public static let text = ActionRequirements(rawValue: 1 << 0)
    /// The selection is in an editable field, so it can be replaced.
    public static let paste = ActionRequirements(rawValue: 1 << 1)

    public func isSatisfied(isEditable: Bool) -> Bool {
        var provided: ActionRequirements = .text
        if isEditable { provided.insert(.paste) }
        return provided.isSuperset(of: self)
    }
}

public struct SelectionInfo: Equatable {
    public var text: String
    public var isEditable: Bool
    public var appBundleID: String?
    public var appName: String?

    public init(text: String, isEditable: Bool, appBundleID: String? = nil, appName: String? = nil) {
        self.text = text
        self.isEditable = isEditable
        self.appBundleID = appBundleID
        self.appName = appName
    }
}

public enum ActionOutcome: Equatable {
    case success
    case failure(String)

    public var isSuccess: Bool { self == .success }
}

/// One button in the popup. Built-ins define these in code, extensions will build them from a manifest.
public struct PopupAction: Identifiable {
    public let id: String
    public let title: String
    /// An emoji or short text, or `symbol:<SF Symbol name>`.
    public let icon: String
    public let requirements: ActionRequirements
    public let run: @MainActor (SelectionInfo, KeyModifiers) async -> ActionOutcome

    public init(
        id: String, title: String, icon: String, requirements: ActionRequirements = .text,
        run: @escaping @MainActor (SelectionInfo, KeyModifiers) async -> ActionOutcome
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.requirements = requirements
        self.run = run
    }

    /// The actions whose requirements the selection meets, in the given order.
    public static func available(_ actions: [PopupAction], for selection: SelectionInfo) -> [PopupAction] {
        guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return actions.filter { $0.requirements.isSatisfied(isEditable: selection.isEditable) }
    }
}
