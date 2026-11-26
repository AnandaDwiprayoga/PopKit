import CoreGraphics

/// Modifier keys, independent of AppKit so the logic below is unit-testable.
public struct KeyModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let command = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// Which input gestures probably just created a text selection.
public enum SelectionGesture {
    /// A drag shorter than this is a click, not a selection.
    public static let dragThreshold: CGFloat = 5

    public static let escapeKeyCode: UInt16 = 53

    private static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]  // left right down up
    private static let extendKeyCodes: Set<UInt16> = [115, 116, 119, 121]  // home pgup end pgdn
    private static let letterAKeyCode: UInt16 = 0

    public static func isSelectionDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) > dragThreshold
    }

    /// Double click selects a word, triple click a line or paragraph.
    public static func isMultiClick(_ clickCount: Int) -> Bool {
        clickCount >= 2
    }

    /// Shift+arrow (and Shift+Home/End/PageUp/PageDown) extend a selection, ⌘A selects all.
    public static func isSelectionKey(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        if modifiers.contains(.shift),
           arrowKeyCodes.contains(keyCode) || extendKeyCodes.contains(keyCode) {
            return true
        }
        return keyCode == letterAKeyCode && modifiers == .command
    }
}
