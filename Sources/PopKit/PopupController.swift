import AppKit
import PopKitCore

/// Ties it together: a selection gesture → check exclusions → read the selection → show the bar.
@MainActor
final class PopupController {
    private let rules: ExclusionRules
    private let reader = SelectionReader()
    private let monitor = SelectionMonitor()
    private let panel = PopupPanel()

    var actions: [PopupAction] = BuiltinActions.all

    /// Bumped on every gesture and dismissal, so a slow ⌘C read can tell it is out of date.
    private var generation = 0
    private var selection: SelectionInfo?

    init(rules: ExclusionRules) {
        self.rules = rules
        monitor.onCandidate = { [weak self] _ in self?.handleCandidate() }
        monitor.onDismiss = { [weak self] in self?.dismiss() }
        monitor.isPopupVisible = { [weak self] in self?.panel.isShowing ?? false }
        panel.model.onSelect = { [weak self] action in self?.perform(action) }
    }

    var isRunning: Bool { monitor.isRunning }

    func start() { monitor.start() }

    func dismiss() {
        generation += 1
        selection = nil
        panel.dismiss()
    }

    // MARK: Selection → popup

    private func handleCandidate() {
        generation += 1
        let current = generation

        let app = NSWorkspace.shared.frontmostApplication
        // Exclusions are checked before any Accessibility call touches the app.
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !rules.shouldSuppress(frontmostBundleID: app.bundleIdentifier) else {
            panel.dismiss()
            return
        }

        let probe = reader.probe(app: app)
        guard !probe.isSecure else {
            panel.dismiss()
            return
        }

        let mouse = NSEvent.mouseLocation
        let anchor = probe.anchor ?? CGRect(origin: mouse, size: .zero)

        if let text = probe.text {
            show(text: text, probe: probe, app: app, anchor: anchor)
        } else if AppQuirks.allowsCopyFallback(app.bundleIdentifier) {
            Task {
                let copied = await reader.readViaCopy()
                guard current == generation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let copied else { return }
                show(text: copied, probe: probe, app: app, anchor: anchor)
            }
        } else {
            panel.dismiss()
        }
    }

    private func show(text: String, probe: SelectionProbe, app: NSRunningApplication, anchor: CGRect) {
        let info = SelectionInfo(
            text: text, isEditable: probe.isEditable,
            appBundleID: app.bundleIdentifier, appName: app.localizedName)
        let available = PopupAction.available(actions, for: info)
        guard !available.isEmpty else {
            panel.dismiss()
            return
        }
        selection = info
        panel.present(actions: available, anchor: anchor)
    }

    // MARK: Running an action

    private func perform(_ action: PopupAction) {
        guard let selection, panel.model.runningID == nil else { return }
        let current = generation
        let modifiers = KeyModifiers(NSEvent.modifierFlags)
        panel.model.runningID = action.id

        Task {
            let outcome = await action.run(selection, modifiers)
            guard current == generation else { return }  // dismissed while it ran
            if case .failure(let message) = outcome { NSLog("PopKit: \(action.title) failed: \(message)") }
            panel.model.runningID = nil
            panel.model.result = outcome
            try? await Task.sleep(nanoseconds: 700_000_000)
            if current == generation { dismiss() }
        }
    }
}
