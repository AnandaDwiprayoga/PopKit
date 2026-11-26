import AppKit
import PopKitCore

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}

/// Watches global mouse and keyboard events and reports when a selection probably just happened.
/// It never reads text itself.
@MainActor
final class SelectionMonitor {
    enum Gesture { case drag, multiClick, keyboard }

    /// Called about 150 ms after a gesture that may have made a selection.
    var onCandidate: ((Gesture) -> Void)?
    /// Called when the popup should go away: a click elsewhere, typing, scrolling, an app switch.
    var onDismiss: (() -> Void)?
    var isPopupVisible: () -> Bool = { false }

    private static let debounce: TimeInterval = 0.15

    private var eventMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var mouseDownLocation: CGPoint = .zero

    var isRunning: Bool { eventMonitor != nil }

    func start() {
        guard !isRunning else { return }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
            .keyDown, .keyUp, .scrollWheel,
        ]
        // Global monitors only see events bound for other apps, so a click on the popup itself
        // never lands here.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        eventMonitor = nil
        activationObserver = nil
        pending?.cancel()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownLocation = NSEvent.mouseLocation
            dismiss()
        case .rightMouseDown, .otherMouseDown:
            dismiss()
        case .leftMouseUp:
            if SelectionGesture.isMultiClick(event.clickCount) {
                schedule(.multiClick)
            } else if SelectionGesture.isSelectionDrag(from: mouseDownLocation, to: NSEvent.mouseLocation) {
                schedule(.drag)
            }
        case .keyDown:
            guard !Keystroke.isRecent else { return }
            dismiss()  // typing, Esc, or any shortcut
        case .keyUp:
            guard !Keystroke.isRecent else { return }
            let modifiers = KeyModifiers(event.modifierFlags)
            if SelectionGesture.isSelectionKey(keyCode: event.keyCode, modifiers: modifiers) {
                schedule(.keyboard)
            }
        case .scrollWheel:
            if isPopupVisible() { dismiss() }
        default:
            break
        }
    }

    private func schedule(_ gesture: Gesture) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onCandidate?(gesture) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func dismiss() {
        pending?.cancel()
        onDismiss?()
    }
}
