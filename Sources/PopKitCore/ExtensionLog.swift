import Foundation
import Combine

/// The last lines an extension printed, plus its errors. Shown in the extension's settings.
@MainActor
public final class ExtensionLog: ObservableObject {
    public static let capacity = 200

    @Published public private(set) var lines: [String] = []

    /// Called for every new line, for the headless CLI.
    public var onLine: ((String) -> Void)?

    public init() {}

    public func append(_ line: String) {
        lines.append(line)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        onLine?(line)
    }

    public func clear() { lines = [] }
}
