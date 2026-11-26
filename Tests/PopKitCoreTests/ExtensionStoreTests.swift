import XCTest
@testable import PopKitCore

final class ExtensionStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PopKitStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bundled"), withIntermediateDirectories: true)
        suite = "PopKitStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    private var bundledDirectory: URL { root.appendingPathComponent("bundled") }

    private func makeStore() -> ExtensionStore {
        ExtensionStore(userDirectory: root.appendingPathComponent("user"), bundledDirectory: bundledDirectory, defaults: defaults)
    }

    private func source(_ folder: String, name: String = "Source", module: String = "index.js", extra: [String: String] = [:]) throws -> URL {
        let directory = root.appendingPathComponent("src").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files = extra
        files["Config.json"] = #"{"name":"\#(name)","module":"\#(module)"}"#
        if module == "index.js" { files["index.js"] = "module.exports = { actions: [] };" }
        return try Fixture.write(files, to: directory)
    }

    private func bundle(_ folder: String) throws {
        let directory = bundledDirectory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Fixture.write(["Config.json": #"{"name":"Built-in"}"#, "index.js": "module.exports = { actions: [] };"], to: directory)
    }

    func testListsBundledThenUserExtensions() async throws {
        try bundle("Copy.popkitext")
        let store = makeStore()
        try store.install(from: source("Zed.popkitext"))
        try store.install(from: source("Alpha.popclipext"))
        XCTAssertEqual(store.all().map(\.id), ["Copy", "Zed", "Alpha"])
        XCTAssertEqual(store.all().map(\.isBundled), [true, false, false])
    }

    func testInstallCopiesTheFolderAndKeepsItsExtension() async throws {
        let store = makeStore()
        let installed = try store.install(from: source("Refine.popclipext", extra: ["lib/x.js": "1"]))
        XCTAssertEqual(installed.id, "Refine")
        XCTAssertEqual(installed.directory.lastPathComponent, "Refine.popclipext")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.directory.appendingPathComponent("lib/x.js").path))
        XCTAssertNotEqual(installed.directory.path, root.appendingPathComponent("src/Refine.popclipext").path)
    }

    func testPreflightReportsReplacementAndRejectsBadFolders() async throws {
        let store = makeStore()
        let folder = try source("Thing.popkitext")
        XCTAssertFalse(try store.preflight(folder).replaces)
        try store.install(from: folder)
        XCTAssertTrue(try store.preflight(folder).replaces)

        XCTAssertThrowsError(try store.preflight(root.appendingPathComponent("missing"))) { error in
            guard case ExtensionError.notADirectory = error else { return XCTFail("\(error)") }
        }
        let empty = root.appendingPathComponent("src/Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.preflight(empty)) { error in
            guard case ExtensionError.missingConfig = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try store.preflight(try source("NoModule.popkitext", module: "gone.js"))) { error in
            XCTAssertEqual(error as? ExtensionError, .missingModule("gone.js"))
        }
    }

    func testReinstallReplacesInPlaceAndKeepsPosition() async throws {
        let store = makeStore()
        try store.install(from: source("A.popkitext"))
        try store.install(from: source("B.popkitext"))
        let updated = try source("A.popkitext", name: "A v2")
        try store.install(from: updated)
        XCTAssertEqual(store.all().map(\.id), ["A", "B"])
        XCTAssertEqual(store.all().first?.manifest.name, "A v2")
    }

    func testCannotShadowABuiltIn() async throws {
        try bundle("Copy.popkitext")
        XCTAssertThrowsError(try makeStore().install(from: source("Copy.popkitext"))) { error in
            XCTAssertEqual(error as? ExtensionError, .conflictsWithBuiltIn("Copy"))
        }
    }

    func testRemoveOnlyRemovesUserExtensions() async throws {
        try bundle("Copy.popkitext")
        let store = makeStore()
        try store.install(from: source("Mine.popkitext"))
        try store.remove("Mine")
        try store.remove("Copy")
        XCTAssertEqual(store.all().map(\.id), ["Copy"])
    }

    func testEnableAndOrderPersist() async throws {
        try bundle("Copy.popkitext")
        let store = makeStore()
        try store.install(from: source("Mine.popkitext"))
        XCTAssertTrue(store.isEnabled("Mine"))
        store.setEnabled(false, id: "Mine")
        store.setOrder(["Mine", "Copy"])

        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isEnabled("Mine"))
        XCTAssertTrue(reloaded.isEnabled("Copy"))
        XCTAssertEqual(reloaded.all().map(\.id), ["Mine", "Copy"])
    }

    func testBrokenExtensionFoldersAreSkipped() async throws {
        let user = root.appendingPathComponent("user/Broken.popkitext")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Fixture.write(["Config.json": "{ nope"], to: user)
        XCTAssertTrue(makeStore().all().isEmpty)
    }
}

@MainActor
final class ExtensionManagerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PopKitManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bundled"), withIntermediateDirectories: true)
        suite = "PopKitManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeManager(host: FakeHost) -> ExtensionManager {
        let store = ExtensionStore(
            userDirectory: root.appendingPathComponent("user"),
            bundledDirectory: root.appendingPathComponent("bundled"), defaults: defaults)
        let manager = ExtensionManager(store: store, options: OptionsStore(defaults: defaults, secrets: InMemorySecrets()))
        manager.host = host
        return manager
    }

    private func write(_ folder: String, config: String, module: String, bundled: Bool = false) throws -> URL {
        let directory = root.appendingPathComponent(bundled ? "bundled" : "src").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try Fixture.write(["Config.json": config, "index.js": module], to: directory)
    }

    func testBuildsPopupActionsInOrderAndFiltersUnsupportedRequirements() async throws {
        let host = FakeHost()
        _ = try write("Copy.popkitext", config: #"{"name":"Copy","icon":"symbol:doc"}"#, module: """
        module.exports = { actions: [{ title: "Copy", code(input) { popclip.copyText(input.text); } }] };
        """, bundled: true)
        let mine = try write("Mine.popkitext", config: #"{"name":"Mine","icon":"M"}"#, module: """
        module.exports = { actions: [
          { title: "Edit", icon: "E", requirements: ["text", "paste"], code() {} },
          { title: "Link", requirements: ["urls"], code() {} }
        ] };
        """)
        let manager = makeManager(host: host)
        try manager.install(from: mine)

        let actions = manager.popupActions()
        XCTAssertEqual(actions.map(\.title), ["Copy", "Edit"])
        XCTAssertEqual(actions.map(\.icon), ["symbol:doc", "E"])
        XCTAssertEqual(actions[1].requirements, [.text, .paste])
        XCTAssertTrue(manager.log(for: "Mine").lines.contains { $0.contains("Link") })

        let outcome = await actions[0].run(SelectionInfo(text: "hi", isEditable: false), [])
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.copied, ["hi"])
    }

    func testDisabledExtensionsDropOutAndChangesNotify() async throws {
        let host = FakeHost()
        let mine = try write("Mine.popkitext", config: #"{"name":"Mine"}"#,
                             module: "module.exports = { actions: [{ title: 'T', code() {} }] };")
        let manager = makeManager(host: host)
        var changes = 0
        manager.onChange = { changes += 1 }
        try manager.install(from: mine)
        XCTAssertEqual(manager.popupActions().count, 1)
        manager.setEnabled(false, id: "Mine")
        XCTAssertTrue(manager.popupActions().isEmpty)
        manager.setEnabled(true, id: "Mine")
        XCTAssertEqual(manager.popupActions().count, 1)
        try manager.remove("Mine")
        XCTAssertTrue(manager.popupActions().isEmpty)
        XCTAssertEqual(changes, 4)
    }

    func testBrokenExtensionIsReportedAndSkipped() async throws {
        let host = FakeHost()
        let broken = try write("Broken.popkitext", config: #"{"name":"Broken"}"#, module: "throw new Error('bad module');")
        let ok = try write("Fine.popkitext", config: #"{"name":"Fine"}"#,
                           module: "module.exports = { actions: [{ title: 'T', code() {} }] };")
        let manager = makeManager(host: host)
        try manager.install(from: broken)
        try manager.install(from: ok)
        XCTAssertEqual(manager.popupActions().map(\.title), ["T"])
        XCTAssertTrue(manager.loadError(for: "Broken")?.contains("bad module") == true)
        XCTAssertNil(manager.loadError(for: "Fine"))
    }

    func testOptionValuesFlowIntoActions() async throws {
        let host = FakeHost()
        let mine = try write("Mine.popkitext", config: #"""
        {"name":"Mine","options":[{"identifier":"engine","type":"multiple","values":["a","b"],"defaultValue":"a"}]}
        """#, module: "module.exports = { actions: [{ title: 'T', code(i, o) { popclip.copyText(o.engine); } }] };")
        let manager = makeManager(host: host)
        try manager.install(from: mine)

        let spec = try XCTUnwrap(manager.store.all().first?.manifest.options.first)
        _ = await manager.popupActions()[0].run(SelectionInfo(text: "x", isEditable: false), [])
        manager.options.set(.string("b"), for: spec, extensionID: "Mine")
        _ = await manager.popupActions()[0].run(SelectionInfo(text: "x", isEditable: false), [])
        XCTAssertEqual(host.copied, ["a", "b"])
    }

    func testPNGIconsResolveToFilePaths() async throws {
        let host = FakeHost()
        let mine = try write("Mine.popkitext", config: #"{"name":"Mine","icon":"icon.png"}"#,
                             module: "module.exports = { actions: [{ title: 'T', code() {} }] };")
        try Fixture.write(["icon.png": "png"], to: mine)
        let manager = makeManager(host: host)
        try manager.install(from: mine)
        XCTAssertTrue(manager.popupActions()[0].icon.hasPrefix("file:"))
        XCTAssertTrue(manager.popupActions()[0].icon.hasSuffix("/Mine.popkitext/icon.png"))
    }
}
