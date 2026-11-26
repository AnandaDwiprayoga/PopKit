import AppKit
import ApplicationServices
import PopKitCore

/// What the accessibility tree says about the focused element.
struct SelectionProbe {
    /// nil when the app doesn't expose its selection through Accessibility at all,
    /// which is when the ⌘C fallback is worth trying. "" means there is no selection.
    var text: String?
    var isEditable = false
    var isSecure = false
    /// Bounds of the selection in AppKit screen coordinates, when the app reports them.
    var anchor: CGRect?
    /// False when no focused element could be read, which usually means the app isn't ready yet.
    var focusFound = false
    /// What Accessibility said, for the debug log. Never includes the selected text.
    var details = "no focused element"
}

private enum AX {
    static let focusedElement = "AXFocusedUIElement"
    static let selectedText = "AXSelectedText"
    static let selectedRange = "AXSelectedTextRange"
    static let boundsForRange = "AXBoundsForRange"
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let value = "AXValue"
    static let editableAncestor = "AXEditableAncestor"
    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"

    static let secureSubrole = "AXSecureTextField"
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
}

@MainActor
final class SelectionReader {
    private var preparedPIDs = Set<pid_t>()

    // MARK: Accessibility

    func probe(app: NSRunningApplication?) -> SelectionProbe {
        var result = SelectionProbe()
        guard let app else { return result }
        guard let element = focusedElement(of: app) else {
            result.details = "no focused element; \(focusErrors(of: app))"
            return result
        }
        result.focusFound = true

        let role = string(element, AX.role) ?? "-"
        let subrole = string(element, AX.subrole) ?? "-"
        if subrole == AX.secureSubrole {
            result.isSecure = true
            result.details = "role=\(role) subrole=\(subrole) secure"
            return result
        }

        result.text = string(element, AX.selectedText)
        result.isEditable = isEditable(element)
        result.anchor = selectionBounds(of: element)
        result.details = "role=\(role) subrole=\(subrole) "
            + "valueSettable=\(isSettable(element, AX.value)) selectedTextSettable=\(isSettable(element, AX.selectedText)) "
            + "editableAncestor=\(self.element(element, AX.editableAncestor) != nil) "
            + "text=\(result.text.map { "\($0.count) chars" } ?? "nil") anchor=\(result.anchor != nil)"
        return result
    }

    private func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        prepare(app)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        if let element = element(systemWide, AX.focusedElement) { return element }

        // Some apps don't answer the system-wide query, so ask the app itself.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        return element(appElement, AX.focusedElement)
    }

    /// AX error codes for the focus queries, for the debug log: -25211 API disabled,
    /// -25204 cannot complete, -25212 no value, -25205 attribute unsupported.
    private func focusErrors(of app: NSRunningApplication) -> String {
        var value: CFTypeRef?
        let systemWide = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), AX.focusedElement as CFString, &value)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focused = AXUIElementCopyAttributeValue(appElement, AX.focusedElement as CFString, &value)
        let manual = AXUIElementSetAttributeValue(appElement, AX.manualAccessibility as CFString, kCFBooleanTrue)
        return "trusted=\(AXIsProcessTrusted()) active=\(app.isActive) systemWide=\(systemWide.rawValue) "
            + "app=\(focused.rawValue) manualAX=\(manual.rawValue)"
    }

    /// Chromium and Electron apps expose almost nothing until asked, once per process.
    private func prepare(_ app: NSRunningApplication) {
        guard preparedPIDs.insert(app.processIdentifier).inserted else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, AX.manualAccessibility as CFString, kCFBooleanTrue)
        if AppQuirks.isChromium(app.bundleIdentifier) {
            AXUIElementSetAttributeValue(appElement, AX.enhancedUserInterface as CFString, kCFBooleanTrue)
        }
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        if let role = string(element, AX.role), AX.editableRoles.contains(role) { return true }
        if isSettable(element, AX.value) || isSettable(element, AX.selectedText) { return true }
        // Web content: a contenteditable region reports the field it lives in.
        return self.element(element, AX.editableAncestor) != nil
    }

    private func selectionBounds(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, AX.selectedRange as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, AX.boundsForRange as CFString, rangeRef, &boundsRef) == .success,
              let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.width >= 0,
              let primary = NSScreen.screens.first else { return nil }

        // Accessibility uses a top-left origin on the primary screen, AppKit a bottom-left one.
        let converted = CGRect(x: rect.minX, y: primary.frame.height - rect.maxY,
                               width: rect.width, height: rect.height)
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(converted) }
        return onScreen ? converted : nil
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    // MARK: ⌘C fallback

    /// For apps that don't expose their selection: press ⌘C, read what lands on the clipboard,
    /// then put the old clipboard back. Returns nil when the clipboard didn't change.
    func readViaCopy() async -> String? {
        let board = NSPasteboard.general
        let saved = PasteboardSnapshot.capture(board)
        let before = board.changeCount

        Keystroke.post(keyCode: Keystroke.keyC, flags: .maskCommand)

        var text: String?
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if board.changeCount != before {
                text = board.string(forType: .string)
                break
            }
        }
        if board.changeCount != before { saved.restore(to: board) }
        return text
    }
}
