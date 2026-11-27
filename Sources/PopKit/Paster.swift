import AppKit

/// Every item and type on the pasteboard, so it can be put back after a paste or a ⌘C probe.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    @MainActor
    static func capture(_ board: NSPasteboard = .general) -> PasteboardSnapshot {
        let items = (board.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
        return PasteboardSnapshot(items: items)
    }

    @MainActor
    func restore(to board: NSPasteboard = .general) {
        board.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(restored)
    }
}

/// Copies text, or replaces the selection by pasting over it.
@MainActor
enum Paster {
    /// Clipboard managers that follow the nspasteboard.org convention skip items with this type.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Puts text on the clipboard for good.
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Writes the text, sends ⌘V to the frontmost app (which still has the selection, because
    /// the popup never takes focus), then puts the old clipboard back when `restore` is set.
    static func paste(_ text: String, restore: Bool = true) async {
        let board = NSPasteboard.general
        let saved = restore ? PasteboardSnapshot.capture(board) : nil

        board.declareTypes([.string, transientType], owner: nil)
        board.setString(text, forType: .string)
        board.setData(Data(), forType: transientType)
        let changeCount = board.changeCount

        try? await Task.sleep(nanoseconds: 50_000_000)
        Keystroke.post(keyCode: Keystroke.keyV, flags: .maskCommand)

        guard let saved else { return }
        // Electron apps (Slack) can read the clipboard well after ⌘V. Restoring too early
        // makes them paste the old clipboard instead of the new text.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Only restore if nothing else (the user's own ⌘C, say) wrote in the meantime.
        if board.changeCount == changeCount { saved.restore(to: board) }
    }
}
