import Foundation
import PopKitCore

/// Actions written in code. The extension runtime replaces these with bundled extensions.
@MainActor
enum BuiltinActions {
    static let copy = PopupAction(
        id: "builtin.copy", title: "Copy", icon: "symbol:doc.on.doc", requirements: .text
    ) { selection, _ in
        Paster.copy(selection.text)
        return .success
    }

    /// Only with POPKIT_DEBUG_ACTIONS=1: replaces the selection with its uppercase form, to
    /// exercise the paste path and the editable check before extensions exist.
    static let debugUppercase = PopupAction(
        id: "debug.uppercase", title: "UPPERCASE (debug)", icon: "AA", requirements: [.text, .paste]
    ) { selection, _ in
        await Paster.paste(selection.text.uppercased(), restore: true)
        return .success
    }

    static var all: [PopupAction] {
        var actions = [copy]
        if ProcessInfo.processInfo.environment["POPKIT_DEBUG_ACTIONS"] == "1" {
            actions.append(debugUppercase)
        }
        return actions
    }
}
