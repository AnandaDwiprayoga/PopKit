import XCTest
@testable import PopKitCore

final class ManifestTests: XCTestCase {
    /// The same shape as Refine.popclipext/Config.json.
    private let refineLike = #"""
    {
      "name": "Refine",
      "description": "Rewrite text.",
      "icon": "✨",
      "entitlements": ["network"],
      "options": [
        { "identifier": "apiKey", "type": "secret", "label": "Groq API key", "description": "d", "keychain": "local" },
        { "identifier": "model", "type": "multiple", "label": "Model",
          "values": ["a", "b", "c"], "defaultValue": "b" },
        { "identifier": "hiddenTerms", "type": "string", "label": "Never send these words" },
        { "identifier": "heading", "type": "heading", "label": "Skipped" },
        { "identifier": "verbose", "type": "boolean", "label": "Verbose", "defaultValue": true }
      ],
      "module": "refine.js"
    }
    """#

    func testParsesRefineStyleManifest() throws {
        let manifest = try ExtensionManifest.parse(Data(refineLike.utf8))
        XCTAssertEqual(manifest.name, "Refine")
        XCTAssertEqual(manifest.icon, "✨")
        XCTAssertEqual(manifest.module, "refine.js")
        XCTAssertTrue(manifest.allowsNetwork)
        XCTAssertEqual(manifest.options.map(\.identifier), ["apiKey", "model", "hiddenTerms", "verbose"])
        XCTAssertEqual(manifest.options.map(\.kind), [.secret, .multiple, .string, .boolean])
        XCTAssertEqual(manifest.options[1].values, ["a", "b", "c"])
        XCTAssertEqual(manifest.options[1].defaultValue, .string("b"))
        XCTAssertEqual(manifest.options[3].defaultValue, .bool(true))
    }

    func testDefaultsForMissingKeys() throws {
        let manifest = try ExtensionManifest.parse(Data(#"{"name":"Tiny"}"#.utf8))
        XCTAssertEqual(manifest.module, "index.js")
        XCTAssertEqual(manifest.entitlements, [])
        XCTAssertFalse(manifest.allowsNetwork)
        XCTAssertTrue(manifest.options.isEmpty)
    }

    func testNameIsRequired() {
        XCTAssertThrowsError(try ExtensionManifest.parse(Data(#"{"icon":"x"}"#.utf8))) { error in
            XCTAssertEqual(error as? ExtensionError, .invalidConfig("\"name\" is required"))
        }
        XCTAssertThrowsError(try ExtensionManifest.parse(Data("not json".utf8)))
    }

    func testPopClipValueLabelsKey() throws {
        let json = #"{"name":"X","options":[{"identifier":"e","type":"multiple","values":["a","b"],"value labels":["A","B"]}]}"#
        let spec = try ExtensionManifest.parse(Data(json.utf8)).options[0]
        XCTAssertEqual(spec.displayLabel(forValue: "b"), "B")
        XCTAssertEqual(spec.displayLabel(forValue: "zzz"), "zzz")
    }

    func testIdComesFromFolderNameOrIdentifier() throws {
        let plain = try ExtensionManifest.parse(Data(#"{"name":"Refine"}"#.utf8))
        XCTAssertEqual(plain.id(directory: URL(fileURLWithPath: "/x/Refine.popclipext")), "Refine")
        let custom = try ExtensionManifest.parse(Data(#"{"name":"Refine","identifier":"com.me.refine"}"#.utf8))
        XCTAssertEqual(custom.id(directory: URL(fileURLWithPath: "/x/Refine.popclipext")), "com.me.refine")
    }

    func testRequirementParsing() {
        XCTAssertEqual(ActionRequirements.parse(["text"]), .text)
        XCTAssertEqual(ActionRequirements.parse(["text", "paste"]), [.text, .paste])
        XCTAssertEqual(ActionRequirements.parse([]), [])
        XCTAssertNil(ActionRequirements.parse(["text", "urls"]))
    }
}

final class OptionsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var secrets: InMemorySecrets!

    private let apiKey = OptionSpec(identifier: "apiKey", kind: .secret)
    private let model = OptionSpec(identifier: "model", kind: .multiple, values: ["a", "b"], defaultValue: .string("b"))
    private let terms = OptionSpec(identifier: "hiddenTerms", kind: .string)
    private let verbose = OptionSpec(identifier: "verbose", kind: .boolean, defaultValue: .bool(true))

    override func setUp() {
        suite = "PopKitOptionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        secrets = InMemorySecrets()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func store(environment: [String: String] = [:]) -> OptionsStore {
        OptionsStore(defaults: defaults, secrets: secrets, environment: environment)
    }

    func testDefaults() {
        let options = store()
        XCTAssertEqual(options.value(for: apiKey, extensionID: "Ext"), .string(""))
        XCTAssertEqual(options.value(for: model, extensionID: "Ext"), .string("b"))
        XCTAssertEqual(options.value(for: terms, extensionID: "Ext"), .string(""))
        XCTAssertEqual(options.value(for: verbose, extensionID: "Ext"), .bool(true))
    }

    func testSecretsGoToTheSecretStoreNotDefaults() {
        let options = store()
        options.set(.string("  sk-123  "), for: apiKey, extensionID: "Ext")
        XCTAssertEqual(secrets.values["Ext.apiKey"], "sk-123")
        XCTAssertEqual(options.value(for: apiKey, extensionID: "Ext"), .string("sk-123"))
        XCTAssertNil(defaults.dictionaryRepresentation().values.first { ($0 as? String)?.contains("sk-123") == true })
    }

    func testPlainValuesPersistPerExtension() {
        let options = store()
        options.set(.string("a"), for: model, extensionID: "One")
        options.set(.bool(false), for: verbose, extensionID: "One")
        XCTAssertEqual(store().value(for: model, extensionID: "One"), .string("a"))
        XCTAssertEqual(store().value(for: model, extensionID: "Two"), .string("b"))
        XCTAssertEqual(store().value(for: verbose, extensionID: "One"), .bool(false))
    }

    func testStoredValueOutsideChoicesFallsBackToDefault() {
        defaults.set("removed-model", forKey: "popkit.ext.Ext.model")
        XCTAssertEqual(store().value(for: model, extensionID: "Ext"), .string("b"))
    }

    func testEnvironmentOverridesStoredValues() {
        let options = store(environment: ["POPKIT_OPT_APIKEY": "from-env", "POPKIT_OPT_VERBOSE": "false"])
        options.set(.string("stored"), for: apiKey, extensionID: "Ext")
        XCTAssertEqual(options.value(for: apiKey, extensionID: "Ext"), .string("from-env"))
        XCTAssertEqual(options.value(for: verbose, extensionID: "Ext"), .bool(false))
    }

    func testClearForgetsEverything() throws {
        let manifest = try ExtensionManifest.parse(Data(#"""
        {"name":"X","options":[{"identifier":"apiKey","type":"secret"},{"identifier":"hiddenTerms","type":"string"}]}
        """#.utf8))
        let options = store()
        options.set(.string("k"), for: apiKey, extensionID: "X")
        options.set(.string("t"), for: terms, extensionID: "X")
        options.clear(manifest, extensionID: "X")
        XCTAssertEqual(options.value(for: apiKey, extensionID: "X"), .string(""))
        XCTAssertEqual(options.value(for: terms, extensionID: "X"), .string(""))
    }
}
