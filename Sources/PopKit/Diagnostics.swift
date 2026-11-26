import Foundation

/// An opt-in log of what PopKit saw when a selection happened: the app, the focused element's
/// accessibility details and which buttons it showed. It never records the selected text.
/// Turn it on in the menu; the file is ~/Library/Logs/PopKit.log.
enum Diagnostics {
    private static let key = "popkit.debugLogging"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PopKit.log")
    }

    static func log(_ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Data("\(stamp) \(line())\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: logURL)
        }
    }
}
