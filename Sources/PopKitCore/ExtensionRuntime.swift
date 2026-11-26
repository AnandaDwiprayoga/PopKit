import Foundation
import JavaScriptCore

public struct ExtensionActionInfo: Equatable {
    public let title: String
    public let icon: String?
    /// Requirement names as the extension wrote them ("text", "paste").
    public let requirements: [String]
}

/// Hands a single result from a JS callback or a timeout to a continuation, once.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func finish(_ message: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: message)
    }
}

/// One extension, running in its own JavaScriptCore context. Created lazily and kept for reuse.
/// Main actor only: JavaScriptCore contexts are not thread-safe.
@MainActor
public final class ExtensionRuntime {
    public static let actionTimeout: TimeInterval = 30

    public let id: String
    public let manifest: ExtensionManifest
    public let directory: URL
    public let log: ExtensionLog
    public private(set) var actions: [ExtensionActionInfo] = []
    public weak var host: ExtensionHost?

    private let context: JSContext
    private var bridge: JSValue?
    private let session: URLSession
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimerID = 1
    private var isRunning = false

    /// Loads the extension's module and reads its actions. Throws `ExtensionError.loadFailed`
    /// when the JavaScript doesn't load.
    public init(
        id: String, manifest: ExtensionManifest, directory: URL, host: ExtensionHost?,
        log: ExtensionLog? = nil, session: URLSession? = nil
    ) throws {
        self.id = id
        self.manifest = manifest
        self.directory = directory
        self.host = host
        self.log = log ?? ExtensionLog()
        self.session = session ?? URLSession(configuration: .ephemeral)
        guard let context = JSContext() else { throw ExtensionError.loadFailed("Could not start JavaScriptCore") }
        self.context = context
        context.exceptionHandler = { ctx, exception in ctx?.exception = exception }

        let native = makeNativeBridge()
        let factory = context.evaluateScript(JSShims.prelude)
        if let message = takeException() { throw ExtensionError.loadFailed("Internal shim error: \(message)") }
        guard let bridge = factory?.call(withArguments: [native]), bridge.isObject else {
            throw ExtensionError.loadFailed("Internal shim error")
        }
        self.bridge = bridge

        let json = bridge.invokeMethod("boot", withArguments: [manifest.module])
        if let message = takeException() { throw ExtensionError.loadFailed(message) }
        guard let json = json?.toString(), let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ExtensionError.loadFailed("The extension's actions could not be read")
        }
        actions = raw.map {
            let title = ($0["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? manifest.name
            return ExtensionActionInfo(
                title: title, icon: $0["icon"] as? String,
                requirements: ($0["requirements"] as? [String]) ?? ["text"])
        }
    }

    // MARK: Running an action

    /// Calls the action's `code(input, options)` and waits for it, including a returned Promise.
    /// A thrown "settings error…" opens the extension's settings. Any other error is a failure.
    public func run(
        actionAt index: Int, selection: SelectionInfo, modifiers: KeyModifiers,
        options: [String: OptionValue]
    ) async -> ActionOutcome {
        guard let bridge, actions.indices.contains(index) else { return .failure("Unknown action") }
        guard !isRunning else { return .failure("This extension is already running an action") }
        isRunning = true
        defer { isRunning = false }

        let payload: [String: Any] = [
            "input": ["text": selection.text],
            "options": options.mapValues(\.jsonObject),
            "modifiers": [
                "shift": modifiers.contains(.shift), "option": modifiers.contains(.option),
                "command": modifiers.contains(.command), "control": modifiers.contains(.control),
            ],
            "context": [
                "appIdentifier": selection.appBundleID ?? "", "appName": selection.appName ?? "",
            ],
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return .failure("Could not encode the action's input")
        }

        let failure: String? = await withCheckedContinuation { continuation in
            let once = OneShot(continuation)
            let ok: @convention(block) () -> Void = { once.finish(nil) }
            let fail: @convention(block) (String) -> Void = { once.finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.actionTimeout) {
                once.finish("Timed out after \(Int(Self.actionTimeout)) seconds")
            }
            bridge.invokeMethod("invoke", withArguments: [index, payloadJSON, ok, fail])
            if let message = takeException() { once.finish(message) }
        }

        guard let failure else { return .success }
        log.append("✗ \(actions[index].title): \(failure)")
        if failure.lowercased().hasPrefix("settings error") { host?.openSettings(forExtension: id) }
        return .failure(failure)
    }

    // MARK: Native bridge

    private func takeException() -> String? {
        guard let exception = context.exception else { return nil }
        context.exception = nil
        if let message = exception.objectForKeyedSubscript("message"), !message.isUndefined {
            return message.toString()
        }
        return exception.toString()
    }

    private func makeNativeBridge() -> JSValue {
        let native = JSValue(newObjectIn: context)!
        func set<T>(_ name: String, _ block: T) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }

        let read: @convention(block) (String) -> Any = { [weak self] file in
            self?.readSource(file) ?? NSNull()
        }
        set("read", read)

        let logLine: @convention(block) (String) -> Void = { [weak self] line in
            self?.log.append(line)
        }
        set("log", logLine)

        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, ms in
            self?.startTimer(callback, milliseconds: ms) ?? 0
        }
        set("setTimeout", setTimeout)

        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.cancel()
        }
        set("clearTimeout", clearTimeout)

        let paste: @convention(block) (String, Bool, JSValue) -> Void = { [weak self] text, restore, done in
            guard let self else { return }
            Task { @MainActor in
                await self.host?.pasteText(text, restore: restore)
                done.call(withArguments: [])
            }
        }
        set("paste", paste)

        let copy: @convention(block) (String) -> Void = { [weak self] text in
            self?.host?.copyText(text)
        }
        set("copy", copy)

        let show: @convention(block) (String, Bool, String) -> Void = { [weak self] text, preview, style in
            let kind: ShowTextStyle = style == "large" ? .large : (preview ? .preview : .plain)
            self?.host?.showText(text, style: kind)
        }
        set("show", show)

        let openURL: @convention(block) (String) -> Void = { [weak self] string in
            guard let url = URL(string: string), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            else { return }
            self?.host?.openURL(url)
        }
        set("openURL", openURL)

        let http: @convention(block) (String, JSValue) -> Void = { [weak self] payload, callback in
            self?.startRequest(payload: payload, callback: callback)
        }
        set("http", http)

        return native
    }

    /// Reads a file inside the extension folder. Nil for anything missing, a directory, or
    /// outside the folder (including through a symlink).
    private func readSource(_ relative: String) -> Any {
        guard !relative.isEmpty else { return NSNull() }
        let root = directory.resolvingSymlinksInPath().path + "/"
        let file = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard file.path.hasPrefix(root),
              FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return NSNull() }
        return text
    }

    private func startTimer(_ callback: JSValue, milliseconds: Double) -> Int {
        let id = nextTimerID
        nextTimerID += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.timers.removeValue(forKey: id)
                callback.call(withArguments: [])
            }
        }
        timers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, milliseconds) / 1000, execute: work)
        return id
    }

    // MARK: axios transport

    private struct HTTPPayload: Decodable {
        let method: String
        let url: String
        let headers: [String: String]
        let data: String?
        let timeout: Double
    }

    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Calls the shim's callback as (kind, status, headersJSON, body, message, code).
    /// kind is "ok" (2xx), "status" (any other HTTP status) or "error" (no response).
    private func startRequest(payload: String, callback: JSValue) {
        func finish(_ kind: String, status: Int = 0, headers: String = "{}", body: String = "",
                    message: String = "", code: String = "") {
            callback.call(withArguments: [kind, status, headers, body, message, code])
        }

        guard manifest.allowsNetwork else {
            finish("error", message: "Network access is not allowed. Add \"network\" to \"entitlements\" in Config.json.",
                   code: "ERR_ENTITLEMENT")
            return
        }
        guard let data = payload.data(using: .utf8),
              let spec = try? JSONDecoder().decode(HTTPPayload.self, from: data),
              let url = URL(string: spec.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            finish("error", message: "Invalid request URL", code: "ERR_INVALID_URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        request.httpShouldHandleCookies = false
        request.timeoutInterval = spec.timeout > 0 ? spec.timeout / 1000 : 60
        for (name, value) in spec.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body = spec.data { request.httpBody = Data(body.utf8) }

        let box = Box(callback)
        let timeoutMs = Int(spec.timeout)
        session.dataTask(with: request) { data, response, error in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var headers = "{}"
            var status = 0
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                var map: [String: String] = [:]
                for (key, value) in http.allHeaderFields { map["\(key)".lowercased()] = "\(value)" }
                headers = (try? JSONSerialization.data(withJSONObject: map)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
            let failure = error as? URLError
            let message = failure?.code == .timedOut ? "timeout of \(timeoutMs)ms exceeded" : (error?.localizedDescription ?? "")
            let code = failure?.code == .timedOut ? "ECONNABORTED" : "ERR_NETWORK"

            DispatchQueue.main.async {
                let callback = box.value
                if status == 0 {
                    callback.call(withArguments: ["error", 0, "{}", "", message, code])
                } else {
                    callback.call(withArguments: [(200..<300).contains(status) ? "ok" : "status", status, headers, text, "", ""])
                }
            }
        }.resume()
    }
}
