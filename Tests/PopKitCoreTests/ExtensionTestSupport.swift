import Foundation
import XCTest
@testable import PopKitCore

/// A host that records what the extension asked for.
@MainActor
final class FakeHost: ExtensionHost {
    var pasted: [(text: String, restore: Bool)] = []
    var copied: [String] = []
    var shown: [(text: String, style: ShowTextStyle)] = []
    var opened: [URL] = []
    var settingsRequests: [String] = []

    func pasteText(_ text: String, restore: Bool) async {
        // A real paste takes a moment, so awaiting it must actually wait.
        try? await Task.sleep(nanoseconds: 20_000_000)
        pasted.append((text, restore))
    }
    func copyText(_ text: String) { copied.append(text) }
    func showText(_ text: String, style: ShowTextStyle) { shown.append((text, style)) }
    func openURL(_ url: URL) { opened.append(url) }
    func openSettings(forExtension id: String) { settingsRequests.append(id) }
}

final class InMemorySecrets: SecretStore {
    var values: [String: String] = [:]
    func secret(for account: String) -> String? { values[account] }
    func setSecret(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { values[account] = nil } else { values[account] = trimmed }
    }
}

/// Answers every request from a closure instead of the network.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        var error: URLError?
    }
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> Reply)?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let reply = Self.handler?(request, body) ?? Reply(status: 500)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Builds throwaway extension folders.
enum Fixture {
    static func makeDirectory(_ name: String = "Fixture.popkitext") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PopKitTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func write(_ files: [String: String], to directory: URL) throws -> URL {
        for (path, content) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return directory
    }

    static func extensionDirectory(
        name: String = "Fixture.popkitext", config: String? = nil, module: String, extra: [String: String] = [:]
    ) throws -> URL {
        let directory = try makeDirectory(name)
        var files = extra
        files["Config.json"] = config ?? #"{"name":"Fixture","entitlements":["network"],"module":"index.js"}"#
        files["index.js"] = module
        return try write(files, to: directory)
    }
}
