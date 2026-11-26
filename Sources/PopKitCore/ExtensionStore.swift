import Foundation

public struct InstalledExtension: Identifiable, Equatable {
    public let id: String
    public let directory: URL
    public let manifest: ExtensionManifest
    /// Shipped inside the app: it can be turned off but not removed.
    public let isBundled: Bool
}

/// What an install would do, for the confirmation dialog.
public struct ExtensionCandidate: Equatable {
    public let id: String
    public let manifest: ExtensionManifest
    /// An extension with this id is already installed and would be replaced.
    public let replaces: Bool
}

/// The extensions on disk: the ones shipped in the app, plus the ones the user installed into
/// ~/Library/Application Support/PopKit/Extensions. Also whether each is enabled, and their order.
public final class ExtensionStore {
    private enum Key {
        static let order = "popkit.extensions.order"
        static let disabled = "popkit.extensions.disabled"
    }

    public static var defaultUserDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PopKit/Extensions", isDirectory: true)
    }

    public static var defaultBundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Extensions", isDirectory: true)
    }

    private let userDirectory: URL
    private let bundledDirectory: URL?
    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    public init(
        userDirectory: URL = ExtensionStore.defaultUserDirectory,
        bundledDirectory: URL? = ExtensionStore.defaultBundledDirectory,
        defaults: UserDefaults = .standard
    ) {
        self.userDirectory = userDirectory
        self.bundledDirectory = bundledDirectory
        self.defaults = defaults
    }

    // MARK: Listing

    /// Every readable extension in the user's order. Folders with a broken Config.json are skipped.
    public func all() -> [InstalledExtension] {
        var found = scan(bundledDirectory, bundled: true) + scan(userDirectory, bundled: false)
        // A user copy never shadows a bundled id.
        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }

        let order = defaults.stringArray(forKey: Key.order) ?? []
        let ranked = order.compactMap { id in found.first { $0.id == id } }
        let rest = found.filter { ext in !order.contains(ext.id) }
        return ranked + rest
    }

    private func scan(_ directory: URL?, bundled: Bool) -> [InstalledExtension] {
        guard let directory,
              let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        return entries
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let manifest = try? ExtensionManifest.load(directory: url) else { return nil }
                return InstalledExtension(id: manifest.id(directory: url), directory: url, manifest: manifest, isBundled: bundled)
            }
    }

    public func isEnabled(_ id: String) -> Bool {
        !(defaults.stringArray(forKey: Key.disabled) ?? []).contains(id)
    }

    public func setEnabled(_ enabled: Bool, id: String) {
        var disabled = Set(defaults.stringArray(forKey: Key.disabled) ?? [])
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(disabled.sorted(), forKey: Key.disabled)
    }

    public func setOrder(_ ids: [String]) {
        defaults.set(ids, forKey: Key.order)
    }

    // MARK: Install and remove

    /// Checks that a folder is an installable extension, without copying anything.
    public func preflight(_ source: URL) throws -> ExtensionCandidate {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExtensionError.notADirectory(source.path)
        }
        let manifest = try ExtensionManifest.load(directory: source)
        guard fileManager.fileExists(atPath: source.appendingPathComponent(manifest.module).path) else {
            throw ExtensionError.missingModule(manifest.module)
        }
        let id = manifest.id(directory: source)
        let installed = all()
        if installed.contains(where: { $0.id == id && $0.isBundled }) {
            throw ExtensionError.conflictsWithBuiltIn(id)
        }
        return ExtensionCandidate(id: id, manifest: manifest, replaces: installed.contains { $0.id == id })
    }

    /// Copies the folder into the user's extensions directory, replacing an installed extension
    /// with the same id. Its option values are kept.
    @discardableResult
    public func install(from source: URL) throws -> InstalledExtension {
        let candidate = try preflight(source)
        try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        let staging = userDirectory.appendingPathComponent(".installing-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        defer { try? fileManager.removeItem(at: staging) }

        if let existing = all().first(where: { $0.id == candidate.id && !$0.isBundled }) {
            try fileManager.removeItem(at: existing.directory)
        }
        let destination = userDirectory.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: staging, to: destination)

        var order = defaults.stringArray(forKey: Key.order) ?? all().map(\.id)
        if !order.contains(candidate.id) { order.append(candidate.id) }
        setOrder(order)

        return InstalledExtension(id: candidate.id, directory: destination, manifest: candidate.manifest, isBundled: false)
    }

    public func remove(_ id: String) throws {
        guard let ext = all().first(where: { $0.id == id && !$0.isBundled }) else { return }
        try fileManager.removeItem(at: ext.directory)
        setOrder((defaults.stringArray(forKey: Key.order) ?? []).filter { $0 != id })
        setEnabled(true, id: id)
    }
}
