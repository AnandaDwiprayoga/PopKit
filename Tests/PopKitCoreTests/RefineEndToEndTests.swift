import XCTest
@testable import PopKitCore

/// Runs every button of the real Refine.popclipext against a stubbed Groq API.
/// Opt-in: set REFINE_EXT_DIR to the Refine.popclipext folder. No network, no key needed.
@MainActor
final class RefineEndToEndTests: XCTestCase {
    private var host: FakeHost!
    private var runtime: ExtensionRuntime!
    private var requests: [(request: URLRequest, json: [String: Any])] = []

    private let good: [String: OptionValue] = [
        "apiKey": .string("test-key"), "model": .string("qwen/qwen3.8-27b"), "hiddenTerms": .string("Project Falcon"),
    ]

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["REFINE_EXT_DIR"] else {
            throw XCTSkip("Set REFINE_EXT_DIR to the Refine.popclipext folder to run this.")
        }
        let directory = URL(fileURLWithPath: path)
        host = FakeHost()
        requests = []
        runtime = try ExtensionRuntime(
            id: "Refine", manifest: ExtensionManifest.load(directory: directory), directory: directory,
            host: host, session: StubURLProtocol.session())
    }

    /// Answers like a model that rewrites by prefixing, keeping placeholders as asked.
    private func installEchoModel(prefix: String = "Rewritten: ") {
        StubURLProtocol.handler = { [unowned self] request, body in
            let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
            requests.append((request, json))
            let messages = json["messages"] as? [[String: Any]] ?? []
            let user = messages.last?["content"] as? String ?? ""
            let draft = user.components(separatedBy: "<text>\n").last?
                .components(separatedBy: "\n</text>").first ?? ""
            let reply = ["choices": [["message": ["content": prefix + draft], "finish_reason": "stop"]]]
            let data = try! JSONSerialization.data(withJSONObject: reply)
            return .init(status: 200, body: String(decoding: data, as: UTF8.self))
        }
    }

    private func index(of title: String) throws -> Int {
        try XCTUnwrap(runtime.actions.firstIndex { $0.title == title }, "no action titled \(title)")
    }

    private func run(_ title: String, _ text: String, editable: Bool = true,
                     modifiers: KeyModifiers = [], options: [String: OptionValue]? = nil) async throws -> ActionOutcome {
        await runtime.run(
            actionAt: try index(of: title), selection: SelectionInfo(text: text, isEditable: editable),
            modifiers: modifiers, options: options ?? good)
    }

    private var rewriteTitles: [String] {
        runtime.actions.filter { $0.requirements == ["text", "paste"] }.map(\.title)
    }

    func testEveryRewriteButtonPastesAndHidesPrivateItemsFromTheRequest() async throws {
        installEchoModel()
        XCTAssertFalse(rewriteTitles.isEmpty)
        let input = "Hey team, see https://intra.example.com/doc?id=42 and mail bob@corp.example about Project Falcon pls"

        for title in rewriteTitles {
            host.pasted.removeAll()
            requests.removeAll()
            let outcome = try await run(title, input)
            XCTAssertEqual(outcome, .success, title)

            let sent = try XCTUnwrap(requests.first, title)
            XCTAssertEqual(sent.request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key", title)
            XCTAssertEqual(sent.json["model"] as? String, "qwen/qwen3.8-27b", title)
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: sent.json), as: UTF8.self)
            for secret in ["intra.example.com", "bob@corp.example", "Project Falcon"] {
                XCTAssertFalse(wire.contains(secret), "\(title) leaked \(secret)")
            }
            XCTAssertTrue(wire.contains("{{LINK_1}}"), title)

            // The hidden items are back in what gets pasted, over the original selection.
            let pasted = try XCTUnwrap(host.pasted.first, title)
            XCTAssertTrue(pasted.text.hasPrefix("Rewritten: "), pasted.text)
            XCTAssertTrue(pasted.text.contains("https://intra.example.com/doc?id=42"), pasted.text)
            XCTAssertTrue(pasted.text.contains("bob@corp.example"), pasted.text)
            XCTAssertTrue(pasted.text.contains("Project Falcon"), pasted.text)
            XCTAssertTrue(pasted.restore, "the clipboard must be restored after pasting")
        }
    }

    func testOptionClickShowsAPreviewInsteadOfPasting() async throws {
        installEchoModel()
        let title = try XCTUnwrap(rewriteTitles.first)
        let outcome = try await run(title, "make this nicer please", modifiers: [.option])
        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(host.pasted.isEmpty)
        XCTAssertEqual(host.shown.map(\.style), [.preview])
        XCTAssertEqual(host.shown.first?.text, "Rewritten: make this nicer please")
    }

    func testSurroundingWhitespaceAndWritersNotes() async throws {
        installEchoModel()
        let title = try XCTUnwrap(rewriteTitles.first)
        _ = try await run(title, "  fix this please /* keep it casual */\n")
        let pasted = try XCTUnwrap(host.pasted.first).text
        XCTAssertTrue(pasted.hasPrefix("  "), "leading whitespace kept: \(pasted.debugDescription)")
        XCTAssertTrue(pasted.hasSuffix("\n"), "trailing whitespace kept: \(pasted.debugDescription)")
        XCTAssertFalse(pasted.contains("casual"), "the note must not end up in the result")
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(requests.first).json), as: UTF8.self)
        XCTAssertTrue(wire.contains("keep it casual"), "the note is sent as context")
    }

    func testTranslateShortShowsPreviewAndLongOpensTheLargeCard() async throws {
        installEchoModel(prefix: "ID: ")
        let title = "Translate to Bahasa Indonesia"

        // Short, read-only selection: a preview (which copies when the field isn't editable).
        var outcome = try await run(title, "Please review the PR today", editable: false)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.shown.map(\.style), [.preview])
        XCTAssertTrue(host.pasted.isEmpty, "translations never replace the selection")

        // Long: copied in full, then the large card.
        host.shown.removeAll()
        let long = String(repeating: "This is a long sentence that needs translating. ", count: 8)
        outcome = try await run(title, long, editable: false)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(host.shown.map(\.style), [.large])
        XCTAssertEqual(host.copied.last, host.shown.last?.text)
        XCTAssertGreaterThan(host.shown.last?.text.count ?? 0, 160)
    }

    func testNothingToRefineSendsNoRequest() async throws {
        installEchoModel()
        let outcome = try await run(try XCTUnwrap(rewriteTitles.first), "https://example.com/only-a-link")
        XCTAssertEqual(outcome, .success)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(host.shown.map(\.text), ["Nothing to refine"])
        XCTAssertEqual(host.shown.map(\.style), [.plain])
        XCTAssertTrue(host.pasted.isEmpty)
    }

    func testFailedPrimaryModelRetriesOnTheFallback() async throws {
        var calls: [String] = []
        StubURLProtocol.handler = { request, body in
            let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
            calls.append(json["model"] as? String ?? "?")
            if calls.count == 1 { return .init(status: 503, body: #"{"error":"overloaded"}"#) }
            return .init(body: #"{"choices":[{"message":{"content":"Recovered"},"finish_reason":"stop"}]}"#)
        }
        let outcome = try await run(try XCTUnwrap(rewriteTitles.first), "please rewrite this sentence")
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(calls, ["qwen/qwen3.8-27b", "openai/gpt-oss-120b"])
        XCTAssertEqual(host.pasted.map(\.text), ["Recovered"])
    }

    func testReplyThatLosesAPlaceholderIsNeverPasted() async throws {
        StubURLProtocol.handler = { _, _ in
            .init(body: #"{"choices":[{"message":{"content":"Rewritten without the link"},"finish_reason":"stop"}]}"#)
        }
        let outcome = try await run(try XCTUnwrap(rewriteTitles.first), "please look at https://intra.example.com/x today")
        guard case .failure = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        XCTAssertTrue(host.pasted.isEmpty)
        XCTAssertTrue(host.settingsRequests.isEmpty, "this is not a settings problem")
    }

    func testMissingOrRejectedKeyOpensRefineSettings() async throws {
        installEchoModel()
        let title = try XCTUnwrap(rewriteTitles.first)

        var outcome = try await run(title, "rewrite me please", options: ["apiKey": .string("")])
        XCTAssertEqual(outcome, .failure("settings error: Groq API key is missing"))
        XCTAssertTrue(requests.isEmpty)

        StubURLProtocol.handler = { _, _ in .init(status: 401, body: #"{"error":{"message":"Invalid API Key"}}"#) }
        outcome = try await run(title, "rewrite me please")
        XCTAssertEqual(outcome, .failure("settings error: Groq API key was rejected"))
        XCTAssertEqual(host.settingsRequests, ["Refine", "Refine"])
        XCTAssertTrue(host.pasted.isEmpty)
    }

    func testDefaultOptionsFromTheManifestSelectTheDefaultModel() throws {
        let manifest = try ExtensionManifest.load(directory: runtime.directory)
        let store = OptionsStore(defaults: UserDefaults(suiteName: "RefineE2E.\(UUID().uuidString)")!, secrets: InMemorySecrets())
        let values = store.values(for: manifest, extensionID: "Refine")
        XCTAssertEqual(values["model"], .string("qwen/qwen3.8-27b"))
        XCTAssertEqual(values["apiKey"], .string(""))
        XCTAssertEqual(values["hiddenTerms"], .string(""))
    }
}
