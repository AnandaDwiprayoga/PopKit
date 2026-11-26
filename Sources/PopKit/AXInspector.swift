import AppKit
import ApplicationServices

/// Dumps the shape of an app's accessibility tree (roles and flags only, never text values), to find
/// out why PopKit can't see a field. Run with `PopKit --probe <bundle id>`.
@MainActor
enum AXInspector {
    static let requestName = Notification.Name("io.github.popkit.probe")

    /// While Debug Logging is on, answers `PopKit --probe <bundle id>` from a terminal by writing
    /// the dump to the log. The terminal itself has no Accessibility access, but this app does.
    static func listenForRequests() {
        DistributedNotificationCenter.default().addObserver(
            forName: requestName, object: nil, queue: .main
        ) { note in
            guard Diagnostics.isEnabled, let id = note.userInfo?["bundleID"] as? String else { return }
            MainActor.assumeIsolated { Diagnostics.log("--- probe \(id) ---\n\(dump(bundleID: id))\n--- end probe ---") }
        }
    }

    static func dump(bundleID: String) -> String {
        var out: [String] = []
        out.append("AX trusted: \(AXIsProcessTrusted())")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return out.joined(separator: "\n") + "\n\(bundleID) is not running"
        }
        out.append("pid \(app.processIdentifier), active=\(app.isActive)")
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)

        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            var current: CFTypeRef?
            let read = AXUIElementCopyAttributeValue(element, name as CFString, &current)
            let set = AXUIElementSetAttributeValue(element, name as CFString, kCFBooleanTrue)
            out.append("\(name): read=\(read.rawValue) (\(describe(current))) set=\(set.rawValue)")
        }
        Thread.sleep(forTimeInterval: 0.5)

        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        out.append("app attributes: \((names as? [String])?.joined(separator: ", ") ?? "?")")

        let systemWide = AXUIElementCreateSystemWide()
        out.append("system-wide focused element: \(describeAttribute(systemWide, "AXFocusedUIElement"))")
        out.append("app focused element: \(describeAttribute(element, "AXFocusedUIElement"))")
        out.append("app focused window: \(describeAttribute(element, "AXFocusedWindow"))")
        out.append("app main window: \(describeAttribute(element, "AXMainWindow"))")

        var windows: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(element, "AXWindows" as CFString, &windows)
        let list = windows as? [AXUIElement] ?? []
        out.append("windows: error=\(windowsError.rawValue) count=\(list.count)")
        var budget = 400
        for (index, window) in list.prefix(2).enumerated() {
            out.append("window \(index + 1):")
            walk(window, depth: 1, maxDepth: 10, budget: &budget, into: &out)
        }
        return out.joined(separator: "\n")
    }

    private static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "element" }
        if let bool = value as? Bool { return "\(bool)" }
        if value is String { return "string" }
        return "\(type(of: value))"
    }

    private static func describeAttribute(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return "error=\(error.rawValue)"
        }
        return summary(value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func flag(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success else { return false }
        return result.boolValue
    }

    /// Role, subrole and flags. No titles, values or descriptions.
    private static func summary(_ element: AXUIElement) -> String {
        var parts = [string(element, "AXRole") ?? "?"]
        if let subrole = string(element, "AXSubrole") { parts.append("sub=\(subrole)") }
        if flag(element, "AXFocused") == true { parts.append("FOCUSED") }
        if settable(element, "AXValue") { parts.append("valueSettable") }
        if settable(element, "AXSelectedText") { parts.append("selTextSettable") }
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        let attributes = (names as? [String]) ?? []
        if attributes.contains("AXSelectedText") { parts.append("hasSelText") }
        if attributes.contains("AXEditableAncestor") { parts.append("hasEditableAncestorAttr") }
        return parts.joined(separator: " ")
    }

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int, into out: inout [String]) {
        guard budget > 0 else { return }
        budget -= 1
        let line = summary(element)
        let interesting = line.contains("FOCUSED") || line.contains("Settable") || line.contains("hasSelText")
            || line.hasPrefix("AXTextArea") || line.hasPrefix("AXTextField") || line.hasPrefix("AXWebArea")
        if interesting || depth <= 3 {
            out.append(String(repeating: "  ", count: depth) + line)
        }
        guard depth < maxDepth else { return }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for kid in kids.prefix(40) { walk(kid, depth: depth + 1, maxDepth: maxDepth, budget: &budget, into: &out) }
    }
}
