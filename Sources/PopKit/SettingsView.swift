import AppKit
import PopKitCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsModel: ObservableObject {
    let rules: ExclusionRules

    @Published var paused: Bool {
        didSet {
            guard paused != rules.isPaused else { return }
            rules.isPaused = paused
            onPauseChange?()
        }
    }
    @Published private(set) var excluded: [String]

    let placement: PlacementRules
    let fields: FieldRules
    @Published var assumeEditable: Bool {
        didSet { fields.assumeEditableWhenUnknown = assumeEditable }
    }
    @Published var defaultSide: PopupSide {
        didSet { placement.defaultSide = defaultSide }
    }
    @Published private(set) var sideOverrides: [String: PopupSide]

    var onPauseChange: (() -> Void)?

    let manager: ExtensionManager
    @Published var tab: SettingsTab = .general
    @Published var selectedExtensionID: String?
    @Published private(set) var extensions: [InstalledExtension]
    /// Opens the folder picker and install dialog (set by the app delegate).
    var onInstallRequest: (() -> Void)?

    init(rules: ExclusionRules, placement: PlacementRules, fields: FieldRules, manager: ExtensionManager) {
        self.rules = rules
        self.placement = placement
        self.fields = fields
        self.assumeEditable = fields.assumeEditableWhenUnknown
        self.manager = manager
        self.extensions = manager.store.all()
        self.paused = rules.isPaused
        self.excluded = rules.excludedBundleIDs
        self.defaultSide = placement.defaultSide
        self.sideOverrides = placement.overrides
    }

    func reloadExtensions() {
        extensions = manager.store.all()
        if let id = selectedExtensionID, !extensions.contains(where: { $0.id == id }) {
            selectedExtensionID = extensions.first?.id
        }
    }

    func moveExtensions(from offsets: IndexSet, to destination: Int) {
        var ids = extensions.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        manager.setOrder(ids)
    }

    func setSide(_ side: PopupSide, for bundleID: String) {
        placement.setSide(side, for: bundleID)
        sideOverrides = placement.overrides
    }

    func removeSide(for bundleID: String) {
        placement.removeOverride(for: bundleID)
        sideOverrides = placement.overrides
    }

    func exclude(_ bundleID: String) {
        rules.exclude(bundleID)
        excluded = rules.excludedBundleIDs
    }

    func include(_ bundleID: String) {
        rules.include(bundleID)
        excluded = rules.excludedBundleIDs
    }
}

enum SettingsTab: Hashable {
    case general, extensions, position, excluded
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ExtensionsTab(model: model)
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.extensions)
            PositionTab(model: model)
                .tabItem { Label("Position", systemImage: "arrow.up.and.down.text.horizontal") }
                .tag(SettingsTab.position)
            ExcludedAppsTab(model: model)
                .tabItem { Label("Excluded Apps", systemImage: "nosign") }
                .tag(SettingsTab.excluded)
        }
        .frame(width: 640, height: 440)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var trusted = Permissions.isTrusted

    var body: some View {
        Form {
            Toggle("Pause PopKit", isOn: $model.paused)

            Picker("Show popup", selection: $model.defaultSide) {
                Text("Above selection").tag(PopupSide.above)
                Text("Below selection").tag(PopupSide.below)
            }

            Toggle("Show rewrite buttons when an app won't say if text is editable", isOn: $model.assumeEditable)
            Text("Slack hides its text fields from other apps. With this on, rewrite buttons also show on read-only text there, where pasting does nothing.")
                .font(.caption).foregroundColor(.secondary)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .disabled(!LoginItem.isInstalledLocation)
                .onChange(of: launchAtLogin) { enabled in
                    try? LoginItem.setEnabled(enabled)
                    if LoginItem.needsApproval { LoginItem.openSystemSettings() }
                    launchAtLogin = LoginItem.isEnabled
                }
            if !LoginItem.isInstalledLocation {
                Text("Install with ./build.sh --install to turn this on.")
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Label(trusted ? "Accessibility access granted" : "Accessibility access needed",
                      systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(trusted ? .green : .orange)
                Spacer()
                if !trusted {
                    Button("Open System Settings") {
                        Permissions.prompt()
                        Permissions.openSystemSettings()
                    }
                }
            }
        }
        .padding(20)
        .onAppear {
            trusted = Permissions.isTrusted
            launchAtLogin = LoginItem.isEnabled
        }
    }
}

private struct PositionTab: View {
    @ObservedObject var model: SettingsModel

    private var sortedIDs: [String] {
        model.sideOverrides.keys.sorted { AppInfo.lookup($0).name.localizedCaseInsensitiveCompare(AppInfo.lookup($1).name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps listed here use their own side. All other apps use “\(model.defaultSide == .above ? "Above" : "Below") selection”.")
                .font(.callout).foregroundColor(.secondary)

            List {
                ForEach(sortedIDs, id: \.self) { id in
                    HStack(spacing: 10) {
                        AppLabel(bundleID: id)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.sideOverrides[id] ?? model.defaultSide },
                            set: { model.setSide($0, for: id) })
                        ) {
                            Text("Above").tag(PopupSide.above)
                            Text("Below").tag(PopupSide.below)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Button { model.removeSide(for: id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Use the default for this app")
                    }
                }
            }
            .overlay {
                if model.sideOverrides.isEmpty {
                    Text("No per-app settings").foregroundColor(.secondary)
                }
            }

            Menu("Add App") {
                ForEach(runningApps(excluding: Set(model.sideOverrides.keys)), id: \.bundleIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                        if let id = app.bundleIdentifier { model.setSide(model.defaultSide.opposite, for: id) }
                    }
                }
                Divider()
                Button("Choose App…") {
                    if let id = chooseAppBundleID() { model.setSide(model.defaultSide.opposite, for: id) }
                }
            }
            .fixedSize()
        }
        .padding(20)
    }
}

private func runningApps(excluding ids: Set<String>) -> [NSRunningApplication] {
    let lowered = Set(ids.map { $0.lowercased() })
    return NSWorkspace.shared.runningApplications
        .filter { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return false }
            return id != Bundle.main.bundleIdentifier && !lowered.contains(id.lowercased())
        }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
}

@MainActor
private func chooseAppBundleID() -> String? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
}

private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let info = AppInfo.lookup(bundleID)
        HStack(spacing: 10) {
            Image(nsImage: info.icon).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.name)
                Text(bundleID).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

private struct ExcludedAppsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PopKit never appears in these apps.")
                .font(.callout).foregroundColor(.secondary)

            List {
                ForEach(model.excluded, id: \.self) { id in
                    AppRow(bundleID: id) { model.include(id) }
                }
            }
            .overlay {
                if model.excluded.isEmpty {
                    Text("No excluded apps").foregroundColor(.secondary)
                }
            }

            Menu("Add App") {
                let running = runningApps()
                ForEach(running, id: \.bundleIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                        if let id = app.bundleIdentifier { model.exclude(id) }
                    }
                }
                Divider()
                Button("Choose App…") { chooseApp() }
            }
            .fixedSize()
        }
        .padding(20)
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !model.excluded.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        model.exclude(id)
    }
}

private struct AppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        let info = AppInfo.lookup(bundleID)
        HStack(spacing: 10) {
            Image(nsImage: info.icon).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.name)
                Text(bundleID).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Stop excluding this app")
        }
    }
}

private struct AppInfo {
    let name: String
    let icon: NSImage

    static func lookup(_ bundleID: String) -> AppInfo {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AppInfo(name: bundleID, icon: NSWorkspace.shared.icon(for: .applicationBundle))
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return AppInfo(
            name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
            icon: NSWorkspace.shared.icon(forFile: url.path))
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "PopKit Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
