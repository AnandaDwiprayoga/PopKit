import Foundation

/// How `popclip.showText` wants its text displayed.
public enum ShowTextStyle: Equatable {
    /// A short notice, hidden after a moment.
    case plain
    /// `{ preview: true }`: click to paste (editable field) or copy.
    case preview
    /// `{ style: "large" }`: a scrollable card with a Copy button.
    case large
}

/// What an extension's `popclip` object calls. The app implements this with the real popup,
/// pasteboard and settings window; tests use a recording fake.
@MainActor
public protocol ExtensionHost: AnyObject {
    func pasteText(_ text: String, restore: Bool) async
    func copyText(_ text: String)
    func showText(_ text: String, style: ShowTextStyle)
    func openURL(_ url: URL)
    /// An action threw "settings error…": show this extension's settings so the user can fix it.
    func openSettings(forExtension id: String)
}
