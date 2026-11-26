import Foundation

/// Turns installed extensions into popup actions, and owns the runtimes behind them.
@MainActor
public final class ExtensionManager {
    public let store: ExtensionStore
    public let options: OptionsStore
    public weak var host: ExtensionHost? {
        didSet { runtimes.values.forEach { $0.host = host } }
    }

    /// Called after anything that changes the list: install, remove, enable, reorder.
    public var onChange: (() -> Void)?

    private let session: URLSession?
    private var runtimes: [String: ExtensionRuntime] = [:]
    private var logs: [String: ExtensionLog] = [:]
    private var loadErrors: [String: String] = [:]
    private var cachedActions: [PopupAction]?

    public init(store: ExtensionStore = ExtensionStore(), options: OptionsStore = OptionsStore(),
                session: URLSession? = nil) {
        self.store = store
        self.options = options
        self.session = session
    }

    public func log(for id: String) -> ExtensionLog {
        if let log = logs[id] { return log }
        let log = ExtensionLog()
        logs[id] = log
        return log
    }

    /// Why an enabled extension isn't showing its actions, if its JavaScript failed to load.
    public func loadError(for id: String) -> String? { loadErrors[id] }

    // MARK: Actions

    /// One action per `actions` entry of every enabled extension, in the user's order.
    /// Extensions load on first use and stay loaded.
    public func popupActions() -> [PopupAction] {
        if let cachedActions { return cachedActions }
        var result: [PopupAction] = []
        for ext in store.all() where store.isEnabled(ext.id) {
            guard let runtime = runtime(for: ext) else { continue }
            for (index, info) in runtime.actions.enumerated() {
                guard let requirements = ActionRequirements.parse(info.requirements) else {
                    log(for: ext.id).append("Skipped \"\(info.title)\": unsupported requirements \(info.requirements)")
                    continue
                }
                let options = self.options
                result.append(PopupAction(
                    id: "\(ext.id)#\(index)", title: info.title,
                    icon: resolveIcon(info.icon ?? ext.manifest.icon, in: ext.directory),
                    requirements: requirements
                ) { selection, modifiers in
                    await runtime.run(
                        actionAt: index, selection: selection, modifiers: modifiers,
                        options: options.values(for: ext.manifest, extensionID: ext.id))
                })
            }
        }
        cachedActions = result
        return result
    }

    private func runtime(for ext: InstalledExtension) -> ExtensionRuntime? {
        if let existing = runtimes[ext.id] { return existing }
        do {
            let runtime = try ExtensionRuntime(
                id: ext.id, manifest: ext.manifest, directory: ext.directory, host: host,
                log: log(for: ext.id), session: session)
            runtimes[ext.id] = runtime
            loadErrors[ext.id] = nil
            return runtime
        } catch {
            let message = error.localizedDescription
            loadErrors[ext.id] = message
            log(for: ext.id).append("✗ Could not load: \(message)")
            return nil
        }
    }

    /// A PNG in the extension folder becomes `file:<path>`. Everything else passes through.
    private func resolveIcon(_ icon: String?, in directory: URL) -> String {
        guard let icon, !icon.isEmpty else { return "•" }
        if icon.lowercased().hasSuffix(".png") {
            let file = directory.appendingPathComponent(icon)
            if FileManager.default.fileExists(atPath: file.path) { return "file:" + file.path }
        }
        return icon
    }

    // MARK: Changes

    /// Forgets loaded extensions so the next popup reads them from disk again.
    public func reload() {
        runtimes.removeAll()
        loadErrors.removeAll()
        cachedActions = nil
        onChange?()
    }

    public func setEnabled(_ enabled: Bool, id: String) {
        store.setEnabled(enabled, id: id)
        cachedActions = nil
        onChange?()
    }

    public func setOrder(_ ids: [String]) {
        store.setOrder(ids)
        cachedActions = nil
        onChange?()
    }

    @discardableResult
    public func install(from source: URL) throws -> InstalledExtension {
        let installed = try store.install(from: source)
        runtimes[installed.id] = nil
        loadErrors[installed.id] = nil
        cachedActions = nil
        onChange?()
        return installed
    }

    public func remove(_ id: String) throws {
        if let ext = store.all().first(where: { $0.id == id }), !ext.isBundled {
            options.clear(ext.manifest, extensionID: id)
        }
        try store.remove(id)
        runtimes[id] = nil
        logs[id] = nil
        loadErrors[id] = nil
        cachedActions = nil
        onChange?()
    }
}
