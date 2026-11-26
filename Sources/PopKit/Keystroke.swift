import AppKit
import CoreGraphics

/// Posts synthetic key presses to the frontmost app.
@MainActor
enum Keystroke {
    // Virtual key codes for the physical key position on a US layout. On layouts that
    // move C or V, the shortcut can miss.
    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9

    private(set) static var lastPosted = Date.distantPast

    /// True just after PopKit posted a key, so the selection monitor can ignore the echo.
    static var isRecent: Bool { Date().timeIntervalSince(lastPosted) < 0.6 }

    static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        lastPosted = Date()
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
