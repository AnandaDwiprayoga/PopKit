import AppKit
import ApplicationServices

/// Accessibility permission: PopKit can't read selections or send ⌘C/⌘V without it.
@MainActor
enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds PopKit to the Accessibility list.
    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private static var pollTimer: Timer?

    /// There is no notification for the grant, so poll until it appears.
    static func waitUntilGranted(_ handler: @escaping @MainActor () -> Void) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard isTrusted else { return }
                timer.invalidate()
                pollTimer = nil
                handler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Explains the permission and sends the user to System Settings.
    static func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "PopKit needs Accessibility access"
        alert.informativeText = """
            PopKit uses Accessibility to see which text you select, and to copy or paste it when you click an action. \
            It only reads a selection when you make one, and never reads password fields.

            Turn on PopKit in System Settings → Privacy & Security → Accessibility. It starts working as soon as you do.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            prompt()
            openSystemSettings()
        }
    }
}
