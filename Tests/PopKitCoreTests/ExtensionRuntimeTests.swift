import XCTest
@testable import PopKitCore

@MainActor
final class ExtensionRuntimeTests: XCTestCase {
    private let selection = SelectionInfo(text: "hello world", isEditable: true, appBundleID: "com.test.app", appName: "Test")

    private func makeRuntime(
        module: String, extra: [String: String] = [:], config: String? = nil,
        host: FakeHost? = nil, session: URLSession? = nil
    ) throws -> ExtensionRuntime {
        let directory = try Fixture.extensionDirectory(config: config, module: module, extra: extra)
        return try ExtensionRuntime(
            id: "Fixture", manifest: ExtensionManifest.load(directory: directory), directory: directory,
            host: host, session: session)
    }

    // MARK: Loader

    func testReadsActionsAndDefaultsRequirements() async throws {
        let runtime = try makeRuntime(module: """
        module.exports = { actions: [
          { title: "A", icon: "🅰", requirements: ["text", "paste"], code() {} },
          { title: "B", code() {} },
          { code() {} }
        ] };
        """)
        XCTAssertEqual(runtime.actions.map(\.title), ["A", "B", "Fixture"])
        XCTAssertEqual(runtime.actions[0].icon, "🅰")
        XCTAssertEqual(runtime.actions[0].requirements, ["text", "paste"])
        XCTAssertEqual(runtime.actions[1].requirements, ["text"])
        XCTAssertNil(runtime.actions[1].icon)
    }

    func testRelativeRequireCachesAndSupportsSubfolders() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        const a = require("./lib/util.js");
        const b = require("./lib/util");        // same module, no extension
        const data = require("./data.json");
        module.exports = { actions: [{ title: "t", code() {
          popclip.copyText([a.count(), b.count(), a === b, data.name, require("./lib/other").up].join(","));
        } }] };
        """, extra: [
            "lib/util.js": "let n = 0; module.exports = { count() { return ++n; } };",
            "lib/other.js": "module.exports = { up: require('../data.json').name + '!' };",
            "data.json": #"{"name":"json"}"#,
        ], host: host)
        let outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.copied, ["1,2,true,json,json!"])
    }

    func testMissingModuleThrowsModuleNotFound() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        function attempt(name) {
          try { require(name); return "loaded"; } catch (e) { return e.code + "|" + e.message; }
        }
        module.exports = { actions: [{ title: "t", code() {
          popclip.copyText([attempt("./local.config.js"), attempt("fs"), attempt("../outside.js"), attempt("./lib")].join("\\n"));
        } }] };
        """, host: host)
        _ = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        let lines = host.copied.first?.components(separatedBy: "\n") ?? []
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("MODULE_NOT_FOUND|") }, "\(lines)")
    }

    func testRequireCannotEscapeTheExtensionFolderThroughASymlink() async throws {
        let outside = try Fixture.makeDirectory("Outside")
        try Fixture.write(["secret.js": "module.exports = 'leaked';"], to: outside)
        let directory = try Fixture.extensionDirectory(module: """
        module.exports = { actions: [{ title: "t", code() {
          try { popclip.copyText(require("./link/secret.js")); } catch (e) { popclip.copyText(e.code); }
        } }] };
        """)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: outside)
        let host = FakeHost()
        let runtime = try ExtensionRuntime(
            id: "Fixture", manifest: ExtensionManifest.load(directory: directory), directory: directory, host: host)
        _ = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(host.copied, ["MODULE_NOT_FOUND"])
    }

    func testProcessIsUndefinedAndRefineStyleConfigPatternWorks() async throws {
        // Mirrors refine's config.js: a missing local file is fine, and `process` must not exist.
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        function loadLocal() {
          try { return require("./local.config.js") || {}; }
          catch (error) {
            if (error && error.code === "MODULE_NOT_FOUND") return {};
            if (error instanceof SyntaxError || typeof process !== "undefined") throw error;
            return {};
          }
        }
        const LOCAL = loadLocal();
        module.exports = { actions: [{ title: "t", code() {
          popclip.copyText(typeof process + "|" + typeof require + "|" + JSON.stringify(LOCAL));
        } }] };
        """, host: host)
        _ = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(host.copied, ["undefined|function|{}"])
    }

    func testLocalConfigIsPickedUpWhenPresent() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        const LOCAL = (() => { try { return require("./local.config.js"); } catch (e) { return {}; } })();
        module.exports = { actions: [{ title: "t", code() { popclip.copyText(LOCAL.name || "none"); } }] };
        """, extra: ["local.config.js": "module.exports = { name: 'mine' };"], host: host)
        _ = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(host.copied, ["mine"])
    }

    func testBrokenModuleFailsToLoad() async throws {
        XCTAssertThrowsError(try makeRuntime(module: "module.exports = {")) { error in
            guard case ExtensionError.loadFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try makeRuntime(module: "module.exports = { actions: [{ title: 'x' }] };")) { error in
            XCTAssertTrue(error.localizedDescription.contains("no code function"), "\(error)")
        }
        XCTAssertThrowsError(try makeRuntime(module: "throw new Error('boom');"), "") { error in
            XCTAssertTrue(error.localizedDescription.contains("boom"))
        }
    }

    func testMissingModuleFileFailsToLoad() async throws {
        let directory = try Fixture.makeDirectory()
        try Fixture.write(["Config.json": #"{"name":"X","module":"nope.js"}"#], to: directory)
        XCTAssertThrowsError(try ExtensionRuntime(
            id: "X", manifest: ExtensionManifest.load(directory: directory), directory: directory, host: nil))
    }

    // MARK: Running actions

    func testInputOptionsModifiersAndContextReachTheAction() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        module.exports = { actions: [{ title: "t", code(input, options) {
          popclip.copyText(JSON.stringify({
            text: input.text, key: options.apiKey, model: options.model, flag: options.flag,
            option: popclip.modifiers.option, shift: popclip.modifiers.shift,
            app: popclip.context.appIdentifier, alias: popkit === popclip
          }));
        } }] };
        """, host: host)
        let outcome = await runtime.run(
            actionAt: 0, selection: selection, modifiers: [.option],
            options: ["apiKey": .string("k"), "model": .string("m"), "flag": .bool(true)])
        XCTAssertEqual(outcome, .success)
        let json = try XCTUnwrap(host.copied.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "hello world")
        XCTAssertEqual(object["key"] as? String, "k")
        XCTAssertEqual(object["model"] as? String, "m")
        XCTAssertEqual(object["flag"] as? Bool, true)
        XCTAssertEqual(object["option"] as? Bool, true)
        XCTAssertEqual(object["shift"] as? Bool, false)
        XCTAssertEqual(object["app"] as? String, "com.test.app")
        XCTAssertEqual(object["alias"] as? Bool, true)
    }

    func testPopclipCallsAreRecorded() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        module.exports = { actions: [{ title: "t", async code(input) {
          popclip.copyText("c");
          popclip.showText("plain");
          popclip.showText("preview", { preview: true });
          popclip.showText("large", { style: "large" });
          popclip.openUrl("https://example.com/?q=" + encodeURIComponent(input.text));
          popclip.openUrl("javascript:alert(1)");   // not a web URL: ignored
          await popclip.pasteText("pasted", { restore: true });
          popclip.copyText("after-paste");          // only runs once the paste finished
        } }] };
        """, host: host)
        let outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.copied, ["c", "after-paste"])
        XCTAssertEqual(host.shown.map(\.text), ["plain", "preview", "large"])
        XCTAssertEqual(host.shown.map(\.style), [.plain, .preview, .large])
        XCTAssertEqual(host.opened.map(\.absoluteString), ["https://example.com/?q=hello%20world"])
        XCTAssertEqual(host.pasted.count, 1)
        XCTAssertEqual(host.pasted.first?.text, "pasted")
        XCTAssertEqual(host.pasted.first?.restore, true)
    }

    func testSettingsErrorOpensSettings() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        module.exports = { actions: [
          { title: "sync", code() { throw new Error("settings error: key is missing"); } },
          { title: "async", async code() { throw new Error("settings error: key was rejected"); } },
          { title: "other", async code() { throw new Error("Groq request failed (500)"); } },
          { title: "string", code() { throw "plain string"; } }
        ] };
        """, host: host)

        var outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .failure("settings error: key is missing"))
        XCTAssertEqual(host.settingsRequests, ["Fixture"])

        outcome = await runtime.run(actionAt: 1, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .failure("settings error: key was rejected"))
        XCTAssertEqual(host.settingsRequests, ["Fixture", "Fixture"])

        outcome = await runtime.run(actionAt: 2, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .failure("Groq request failed (500)"))
        outcome = await runtime.run(actionAt: 3, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .failure("plain string"))
        XCTAssertEqual(host.settingsRequests.count, 2, "only settings errors open settings")
        XCTAssertTrue(runtime.log.lines.contains { $0.contains("Groq request failed (500)") })
    }

    func testPrintAndConsoleGoToTheLog() async throws {
        let runtime = try makeRuntime(module: """
        module.exports = { actions: [{ title: "t", code() { print("a", 1, { b: 2 }); console.log("c"); } }] };
        """)
        _ = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(runtime.log.lines, [#"a 1 {"b":2}"#, "c"])
    }

    func testLogKeepsOnlyTheLastLines() async {
        let log = ExtensionLog()
        for i in 0..<(ExtensionLog.capacity + 25) { log.append("line \(i)") }
        XCTAssertEqual(log.lines.count, ExtensionLog.capacity)
        XCTAssertEqual(log.lines.first, "line 25")
    }

    func testSetTimeoutAndClearTimeout() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        module.exports = { actions: [{ title: "t", code() {
          return new Promise((resolve) => {
            const cancelled = setTimeout(() => popclip.copyText("cancelled"), 10);
            clearTimeout(cancelled);
            setTimeout((word) => { popclip.copyText(word); resolve(); }, 30, "fired");
          });
        } }] };
        """, host: host)
        let outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.copied, ["fired"])
    }

    func testStateDoesNotLeakBetweenRuns() async throws {
        let host = FakeHost()
        let runtime = try makeRuntime(module: """
        module.exports = { actions: [{ title: "t", code(input) { popclip.copyText(String(popclip.modifiers.option)); } }] };
        """, host: host)
        _ = await runtime.run(actionAt: 0, selection: selection, modifiers: [.option], options: [:])
        _ = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(host.copied, ["true", "false"])
    }

    // MARK: axios

    private let axiosModule = """
    const axios = require("axios");
    const report = (value) => popclip.copyText(JSON.stringify(value));
    module.exports = { actions: [
      { title: "ok", async code() {
        const r = await axios.post("https://api.test/v1/chat", { a: 1 },
          { headers: { Authorization: "Bearer key" }, timeout: 5000 });
        report([r.status, r.data, r.headers["x-test"]]);
      } },
      { title: "status", async code() {
        try { await axios.post("https://api.test/v1/chat", {}); report("resolved"); }
        catch (error) { report([error.response.status, error.response.data, error.isAxiosError]); }
      } },
      { title: "timeout", async code() {
        try { await axios.get("https://api.test/slow", { timeout: 250 }); report("resolved"); }
        catch (error) { report([error.response === undefined, error.code, error.message]); }
      } },
      { title: "get", async code() {
        const r = await axios.get("https://api.test/search", { params: { q: "a b", n: 2 } });
        report(r.data);
      } },
      { title: "text", async code() {
        const r = await axios.get("https://api.test/text");
        report([typeof r.data, r.data]);
      } }
    ] };
    """

    private func decodedReport(_ host: FakeHost) throws -> [Any] {
        let json = try XCTUnwrap(host.copied.last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) as? [Any])
    }

    func testAxiosPostSuccessResolvesStatusAndParsedData() async throws {
        var seen: (request: URLRequest, body: String)?
        StubURLProtocol.handler = { request, body in
            seen = (request, String(decoding: body ?? Data(), as: UTF8.self))
            return .init(status: 200, body: #"{"choices":[{"text":"hi"}]}"#, headers: ["X-Test": "yes"])
        }
        let host = FakeHost()
        let runtime = try makeRuntime(module: axiosModule, host: host, session: StubURLProtocol.session())
        let outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .success)

        let request = try XCTUnwrap(seen?.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/chat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(seen?.body, #"{"a":1}"#)
        XCTAssertEqual(request.timeoutInterval, 5, accuracy: 0.001)

        let report = try decodedReport(host)
        XCTAssertEqual(report[0] as? Int, 200)
        XCTAssertEqual((report[1] as? [String: Any])?["choices"] is [Any], true)
        XCTAssertEqual(report[2] as? String, "yes")
    }

    func testAxios401RejectsWithResponseStatusAndData() async throws {
        StubURLProtocol.handler = { _, _ in .init(status: 401, body: #"{"error":{"message":"bad key"}}"#) }
        let host = FakeHost()
        let runtime = try makeRuntime(module: axiosModule, host: host, session: StubURLProtocol.session())
        let outcome = await runtime.run(actionAt: 1, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .success)
        let report = try decodedReport(host)
        XCTAssertEqual(report[0] as? Int, 401)
        XCTAssertEqual(((report[1] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String, "bad key")
        XCTAssertEqual(report[2] as? Bool, true)
    }

    func testAxiosTimeoutRejectsWithoutResponse() async throws {
        StubURLProtocol.handler = { _, _ in .init(error: URLError(.timedOut)) }
        let host = FakeHost()
        let runtime = try makeRuntime(module: axiosModule, host: host, session: StubURLProtocol.session())
        let outcome = await runtime.run(actionAt: 2, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .success)
        let report = try decodedReport(host)
        XCTAssertEqual(report[0] as? Bool, true)
        XCTAssertEqual(report[1] as? String, "ECONNABORTED")
        XCTAssertEqual(report[2] as? String, "timeout of 250ms exceeded")
    }

    func testAxiosIsRefusedWithoutTheNetworkEntitlement() async throws {
        var requests = 0
        StubURLProtocol.handler = { _, _ in requests += 1; return .init() }
        let host = FakeHost()
        let runtime = try makeRuntime(
            module: axiosModule, config: #"{"name":"Fixture","module":"index.js"}"#,
            host: host, session: StubURLProtocol.session())
        let outcome = await runtime.run(actionAt: 2, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(requests, 0, "no request may leave without the entitlement")
        let report = try decodedReport(host)
        XCTAssertEqual(report[0] as? Bool, true)
        XCTAssertEqual(report[1] as? String, "ERR_ENTITLEMENT")
        XCTAssertTrue((report[2] as? String)?.contains("entitlements") == true)
    }

    func testAxiosGetEncodesParamsAndTextBodiesStayStrings() async throws {
        var seenURL: String?
        StubURLProtocol.handler = { request, _ in
            seenURL = request.url?.absoluteString
            return request.url?.path == "/text" ? .init(body: "plain words") : .init(body: #"{"ok":true}"#)
        }
        let host = FakeHost()
        let runtime = try makeRuntime(module: axiosModule, host: host, session: StubURLProtocol.session())

        _ = await runtime.run(actionAt: 3, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(seenURL, "https://api.test/search?q=a%20b&n=2")
        XCTAssertEqual(host.copied.last, #"{"ok":true}"#)  // a JSON body arrives parsed

        _ = await runtime.run(actionAt: 4, selection: selection, modifiers: [], options: [:])
        let report = try decodedReport(host)
        XCTAssertEqual(report[0] as? String, "string")
        XCTAssertEqual(report[1] as? String, "plain words")
    }

    func testRejectedRequestWithoutCatchBecomesAFailedAction() async throws {
        StubURLProtocol.handler = { _, _ in .init(status: 500, body: "oops") }
        let runtime = try makeRuntime(module: """
        const axios = require("axios");
        module.exports = { actions: [{ title: "t", async code() { await axios.get("https://api.test/x"); } }] };
        """, session: StubURLProtocol.session())
        let outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: [:])
        XCTAssertEqual(outcome, .failure("Request failed with status code 500"))
    }

    // MARK: Fixture that mirrors Refine's usage

    func testRefineShapedExtensionEndToEnd() async throws {
        StubURLProtocol.handler = { request, body in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            guard auth == "Bearer good-key" else { return .init(status: 401, body: #"{"error":"nope"}"#) }
            return .init(body: #"{"choices":[{"message":{"content":"Fixed text."}}]}"#)
        }
        let module = """
        const axios = require("axios");
        async function callApi(apiKey) {
          try {
            const response = await axios.post("https://api.test/chat", { messages: [] },
              { headers: { Authorization: "Bearer " + apiKey }, timeout: 15000 });
            return response.data.choices[0].message.content;
          } catch (error) {
            const wrapped = new Error("request failed (" + (error.response && error.response.status || error.message) + ")");
            wrapped.status = error.response && error.response.status;
            throw wrapped;
          }
        }
        async function run(input, options) {
          const apiKey = (options.apiKey || "").trim();
          if (!apiKey) throw new Error("settings error: API key is missing");
          let result;
          try { result = await callApi(apiKey); }
          catch (error) {
            if (error.status === 401) throw new Error("settings error: API key was rejected");
            throw error;
          }
          if (popclip.modifiers.option) popclip.showText(result, { preview: true });
          else await popclip.pasteText(result, { restore: true });
        }
        module.exports = { actions: [
          { title: "Fix", icon: "🛠", requirements: ["text", "paste"], code: (i, o) => run(i, o) },
          { title: "Translate", icon: "🇮🇩", requirements: ["text"], code: (i, o) => run(i, o) }
        ] };
        """
        let host = FakeHost()
        let runtime = try makeRuntime(module: module, host: host, session: StubURLProtocol.session())
        XCTAssertEqual(runtime.actions.map(\.requirements), [["text", "paste"], ["text"]])

        // No key → settings.
        var outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: ["apiKey": .string("")])
        XCTAssertEqual(outcome, .failure("settings error: API key is missing"))
        // Bad key → 401 → settings.
        outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: ["apiKey": .string("bad")])
        XCTAssertEqual(outcome, .failure("settings error: API key was rejected"))
        XCTAssertEqual(host.settingsRequests.count, 2)
        XCTAssertTrue(host.pasted.isEmpty)

        // Good key → pasted; with ⌥ → preview instead.
        outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [], options: ["apiKey": .string("good-key")])
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.pasted.map(\.text), ["Fixed text."])
        outcome = await runtime.run(actionAt: 0, selection: selection, modifiers: [.option], options: ["apiKey": .string("good-key")])
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.pasted.count, 1)
        XCTAssertEqual(host.shown.last?.style, .preview)
    }

    // MARK: The real Refine extension (opt-in)

    func testRealRefineExtensionLoads() async throws {
        guard let path = ProcessInfo.processInfo.environment["REFINE_EXT_DIR"] else {
            throw XCTSkip("Set REFINE_EXT_DIR to the Refine.popclipext folder to run this.")
        }
        let directory = URL(fileURLWithPath: path)
        let manifest = try ExtensionManifest.load(directory: directory)
        let runtime = try ExtensionRuntime(id: "Refine", manifest: manifest, directory: directory, host: FakeHost())
        XCTAssertFalse(runtime.actions.isEmpty)
        XCTAssertTrue(runtime.actions.contains { $0.requirements == ["text", "paste"] })
        XCTAssertTrue(runtime.actions.contains { $0.requirements == ["text"] })
        // Without a key, every action asks for settings.
        let host = FakeHost()
        runtime.host = host
        let outcome = await runtime.run(
            actionAt: 0, selection: selection, modifiers: [], options: ["apiKey": .string("")])
        XCTAssertEqual(outcome, .failure("settings error: Groq API key is missing"))
        XCTAssertEqual(host.settingsRequests, ["Refine"])
    }
}
