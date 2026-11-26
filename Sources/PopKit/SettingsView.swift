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

    var onPauseChange: (() -> Void)?

    init(rules: ExclusionRules) {
        self.rules = rules
        self.paused = rules.isPaused
        self.excluded = rules.excludedBundleIDs
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ExcludedAppsTab(model: model)
                .tabItem { Label("Excluded Apps", systemImage: "nosign") }
        }
        .frame(width: 460, height: 360)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var trusted = Permissions.isTrusted

    var body: some View {
        Form {
            Toggle("Pause PopKit", isOn: $model.paused)

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
