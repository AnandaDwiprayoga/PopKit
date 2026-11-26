import ApplicationServices
import Foundation
import PopKitCore

/// Headless commands, for scripting and for checking an extension without clicking:
///
///   PopKit --list <extension folder>
///   PopKit --run <extension folder> <action title or number> <text> [--modifiers option,shift] [--editable]
///   PopKit --install <extension folder>
///
/// Option values come from the environment (POPKIT_OPT_APIKEY, POPKIT_OPT_MODEL, …), then the
/// Keychain, then the extension's defaults. Exit codes: 0 done, 1 error, 2 the extension asked for settings.
@MainActor
enum CLI {
    /// The runtime only holds its host weakly, so this keeps it alive.
    private static let host = CLIHost()

    private static let commands: Set<String> = ["--run", "--list", "--install", "--probe", "--help"]

    static func handles(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return commands.contains(first)
    }

    private static let usage = """
        Usage:
          PopKit --list <extension folder>
          PopKit --run <extension folder> <action title or number> <text> [--modifiers option,shift] [--editable]
          PopKit --install <extension folder>
          PopKit --probe <bundle id>      (debugging: show an app's accessibility structure, no text)

        Options come from POPKIT_OPT_<NAME> environment variables, then the Keychain, then defaults.
        """

    static func run(_ arguments: [String]) async -> Int32 {
        var arguments = arguments
        let command = arguments.removeFirst()
        switch command {
        case "--list": return list(arguments)
        case "--run": return await runAction(arguments)
        case "--install": return install(arguments)
        case "--probe":
            guard let id = arguments.first else { return fail("--probe needs a bundle id, e.g. com.tinyspeck.slackmacgap") }
            if AXIsProcessTrusted() {
                print(AXInspector.dump(bundleID: id))
            } else {
                // A terminal-launched process has no Accessibility access. Ask the running app, which does.
                DistributedNotificationCenter.default().postNotificationName(
                    AXInspector.requestName, object: nil, userInfo: ["bundleID": id], deliverImmediately: true)
                print("Asked the running PopKit to probe \(id). With Debug Logging on, the result is in \(Diagnostics.logURL.path).")
            }
            return 0
        default:
            print(usage)
            return 0
        }
    }

    // MARK: Commands

    private static func list(_ arguments: [String]) -> Int32 {
        guard let path = arguments.first else { return fail("--list needs an extension folder") }
        do {
            let (runtime, _) = try load(path)
            for (index, action) in runtime.actions.enumerated() {
                print("\(index + 1). \(action.title)  [\(action.requirements.joined(separator: ", "))]")
            }
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func install(_ arguments: [String]) -> Int32 {
        guard let path = arguments.first else { return fail("--install needs an extension folder") }
        do {
            let installed = try ExtensionStore().install(from: URL(fileURLWithPath: path))
            print("Installed \"\(installed.manifest.name)\" (\(installed.id)) to \(installed.directory.path)")
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func runAction(_ arguments: [String]) async -> Int32 {
        var positional: [String] = []
        var modifiers: KeyModifiers = []
        var editable = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--editable": editable = true
            case "--modifiers":
                for name in (rest.popFirst() ?? "").split(separator: ",") {
                    switch name {
                    case "shift": modifiers.insert(.shift)
                    case "option": modifiers.insert(.option)
                    case "command": modifiers.insert(.command)
                    case "control": modifiers.insert(.control)
                    default: return fail("Unknown modifier \"\(name)\". Use shift, option, command or control.")
                    }
                }
            default: positional.append(argument)
            }
        }
        guard positional.count == 3 else { return fail("--run needs: <extension folder> <action> <text>") }

        do {
            let (runtime, manifest) = try load(positional[0])
            let query = positional[1]
            let index = Int(query).map { $0 - 1 }
                ?? runtime.actions.firstIndex { $0.title.caseInsensitiveCompare(query) == .orderedSame }
            guard let index, runtime.actions.indices.contains(index) else {
                return fail("No action \"\(query)\". Try --list.")
            }

            let action = runtime.actions[index]
            if let needed = ActionRequirements.parse(action.requirements), !needed.isSatisfied(isEditable: editable) {
                FileHandle.standardError.write(Data("note: \"\(action.title)\" needs an editable field. Pass --editable to match the popup.\n".utf8))
            }

            let options = OptionsStore(environment: ProcessInfo.processInfo.environment)
            let selection = SelectionInfo(text: positional[2], isEditable: editable, appBundleID: "cli", appName: "PopKit CLI")
            let outcome = await runtime.run(
                actionAt: index, selection: selection, modifiers: modifiers,
                options: options.values(for: manifest, extensionID: runtime.id))

            switch outcome {
            case .success:
                return 0
            case .failure(let message):
                print("ERROR: \(message)")
                return message.lowercased().hasPrefix("settings error") ? 2 : 1
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private static func load(_ path: String) throws -> (ExtensionRuntime, ExtensionManifest) {
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let manifest = try ExtensionManifest.load(directory: directory)
        let log = ExtensionLog()
        log.onLine = { FileHandle.standardError.write(Data(("[log] " + $0 + "\n").utf8)) }
        let runtime = try ExtensionRuntime(
            id: manifest.id(directory: directory), manifest: manifest, directory: directory,
            host: host, log: log)
        return (runtime, manifest)
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 1
    }
}

/// Prints what an extension would have done to the screen and clipboard.
@MainActor
private final class CLIHost: ExtensionHost {
    func pasteText(_ text: String, restore: Bool) async { print("PASTE: \(text)") }
    func copyText(_ text: String) { print("COPY: \(text)") }
    func showText(_ text: String, style: ShowTextStyle) {
        let label = style == .large ? "SHOW (large)" : style == .preview ? "SHOW (preview)" : "SHOW"
        print("\(label): \(text)")
    }
    func openURL(_ url: URL) { print("OPEN: \(url.absoluteString)") }
    func openSettings(forExtension id: String) { print("SETTINGS: open \(id)") }
}
