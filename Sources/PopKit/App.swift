import AppKit
import PopKitCore

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let rules = ExclusionRules()

    /// The last frontmost app that isn't PopKit, for "Exclude <app>".
    private var lastActiveApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        trackFrontmostApp()
        LoginItem.enableOnFirstRun()
    }

    // MARK: Menu

    /// Rebuilt each time it opens so the titles and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pause = NSMenuItem(title: "Pause PopKit", action: #selector(togglePause), keyEquivalent: "")
        pause.state = rules.isPaused ? .on : .off
        pause.target = self
        menu.addItem(pause)

        let exclude = NSMenuItem(title: excludeTitle, action: #selector(excludeLastApp), keyEquivalent: "")
        exclude.target = self
        exclude.isEnabled = excludableApp != nil
        menu.addItem(exclude)

        menu.addItem(.separator())

        // Wired up in the extension runtime milestone.
        let install = NSMenuItem(title: "Install Extension…", action: nil, keyEquivalent: "")
        install.isEnabled = false
        menu.addItem(install)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        login.isEnabled = LoginItem.isInstalledLocation
        menu.addItem(login)

        menu.addItem(.separator())

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let about = NSMenuItem(title: "PopKit \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit PopKit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private var excludableApp: NSRunningApplication? {
        guard let app = lastActiveApp, app.bundleIdentifier != nil else { return nil }
        return app
    }

    private var excludeTitle: String {
        guard let app = excludableApp, let name = app.localizedName else { return "Exclude Current App" }
        return rules.isExcluded(app.bundleIdentifier) ? "\(name) Is Excluded" : "Exclude \(name)"
    }

    @objc private func togglePause() {
        rules.isPaused.toggle()
        updateIcon()
    }

    @objc private func excludeLastApp() {
        guard let id = excludableApp?.bundleIdentifier else { return }
        rules.exclude(id)
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            NSLog("PopKit: launch at login failed: \(error)")
        }
        if LoginItem.needsApproval { LoginItem.openSystemSettings() }
    }

    // MARK: Status item

    private func updateIcon() {
        let symbol = rules.isPaused ? "pause.circle" : "text.cursor"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PopKit")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = rules.isPaused ? "PopKit (paused)" : "PopKit"
    }

    // MARK: Frontmost app tracking

    private func trackFrontmostApp() {
        remember(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastActiveApp = app
    }
}
