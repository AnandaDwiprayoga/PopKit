import AppKit
import PopKitCore

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if CLI.handles(arguments) {
            Task { @MainActor in exit(await CLI.run(arguments)) }
            dispatchMain()
        }

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
    private let placement = PlacementRules()
    private let manager = ExtensionManager()
    private lazy var settingsModel = SettingsModel(rules: rules, placement: placement, manager: manager)
    private lazy var settingsWindow = SettingsWindowController(model: settingsModel)
    private lazy var popup = PopupController(rules: rules, placement: placement, manager: manager)

    /// The last frontmost app that isn't PopKit, for "Exclude <app>".
    private var lastActiveApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        settingsModel.onPauseChange = { [weak self] in
            self?.updateIcon()
            self?.popup.dismiss()
        }

        manager.onChange = { [weak self] in self?.settingsModel.reloadExtensions() }
        settingsModel.onInstallRequest = { [weak self] in self?.installExtension() }
        popup.onOpenSettings = { [weak self] id in self?.showSettings(extensionID: id) }

        trackFrontmostApp()
        LoginItem.enableOnFirstRun()
        startWhenTrusted()
    }

    /// Global event monitors only work once Accessibility is granted, so start them then.
    private func startWhenTrusted() {
        if Permissions.isTrusted {
            popup.start()
            return
        }
        Permissions.waitUntilGranted { [weak self] in self?.popup.start() }
        DispatchQueue.main.async { Permissions.showOnboarding() }
    }

    // MARK: Menu

    /// Rebuilt each time it opens so the titles and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Permissions.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            menu.addItem(.separator())
        }

        let pause = NSMenuItem(title: "Pause PopKit", action: #selector(togglePause), keyEquivalent: "")
        pause.state = rules.isPaused ? .on : .off
        pause.target = self
        menu.addItem(pause)

        let exclude = NSMenuItem(title: excludeTitle, action: #selector(excludeLastApp), keyEquivalent: "")
        exclude.target = self
        exclude.isEnabled = excludableApp != nil && !rules.isExcluded(excludableApp?.bundleIdentifier)
        menu.addItem(exclude)

        let side = NSMenuItem(title: sideTitle, action: #selector(flipSideForLastApp), keyEquivalent: "")
        side.target = self
        side.isEnabled = excludableApp != nil
        menu.addItem(side)

        menu.addItem(.separator())

        let install = NSMenuItem(title: "Install Extension…", action: #selector(installExtension), keyEquivalent: "")
        install.target = self
        menu.addItem(install)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

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

    private var currentSide: PopupSide { placement.side(for: excludableApp?.bundleIdentifier) }

    private var sideTitle: String {
        let target = currentSide.opposite == .below ? "Below" : "Above"
        guard let name = excludableApp?.localizedName else { return "Show Popup \(target) Text" }
        return "Show Popup \(target) Text in \(name)"
    }

    /// Moves the last active app to the other side. Going back to the default drops the override.
    @objc private func flipSideForLastApp() {
        guard let id = excludableApp?.bundleIdentifier else { return }
        let target = currentSide.opposite
        if target == placement.defaultSide {
            settingsModel.removeSide(for: id)
        } else {
            settingsModel.setSide(target, for: id)
        }
    }

    @objc private func grantAccess() {
        Permissions.prompt()
        Permissions.openSystemSettings()
        if !popup.isRunning {
            Permissions.waitUntilGranted { [weak self] in self?.popup.start() }
        }
    }

    @objc private func togglePause() {
        settingsModel.paused.toggle()
    }

    @objc private func excludeLastApp() {
        guard let id = excludableApp?.bundleIdentifier else { return }
        settingsModel.exclude(id)
        popup.dismiss()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    private func showSettings(extensionID: String) {
        settingsModel.tab = .extensions
        settingsModel.selectedExtensionID = extensionID
        settingsWindow.show()
    }

    // MARK: Installing extensions

    @objc private func installExtension() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose an extension folder (.popkitext or .popclipext)"
        panel.prompt = "Choose"
        panel.canChooseFiles = true  // a .popkitext folder is a package, which the panel treats as a file
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        install(urls: panel.urls)
    }

    /// Also reached by dropping an extension folder on the app's icon in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        install(urls: urls)
    }

    private func install(urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        for url in urls {
            do {
                let candidate = try manager.store.preflight(url)
                guard confirmInstall(candidate) else { continue }
                let installed = try manager.install(from: url)
                showSettings(extensionID: installed.id)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func confirmInstall(_ candidate: ExtensionCandidate) -> Bool {
        let manifest = candidate.manifest
        var lines: [String] = []
        if let description = manifest.description { lines.append(description) }
        if manifest.allowsNetwork { lines.append("This extension can use the network.") }
        if candidate.replaces { lines.append("It replaces the installed version. Your settings for it are kept.") }
        lines.append("Extensions run code on your Mac and can see the text you select. Only install extensions you trust.")

        let alert = NSAlert()
        alert.messageText = "Install “\(manifest.name)”?"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: candidate.replaces ? "Replace" : "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
