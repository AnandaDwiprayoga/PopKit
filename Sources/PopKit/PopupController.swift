import AppKit
import PopKitCore

/// Ties it together: a selection gesture → check exclusions → read the selection → show the bar.
/// It is also the host that extensions talk to: paste, copy, showText, openUrl.
@MainActor
final class PopupController: ExtensionHost {
    private let rules: ExclusionRules
    private let placement: PlacementRules
    private let manager: ExtensionManager
    private let reader = SelectionReader()
    private let monitor = SelectionMonitor()
    private let panel = PopupPanel()

    /// Shows an extension's settings (set by the app delegate).
    var onOpenSettings: ((String) -> Void)?

    /// Bumped on every gesture and dismissal, so a slow ⌘C read can tell it is out of date.
    private var generation = 0
    private var selection: SelectionInfo?

    init(rules: ExclusionRules, placement: PlacementRules, manager: ExtensionManager) {
        self.rules = rules
        self.placement = placement
        self.manager = manager
        manager.host = self
        monitor.onCandidate = { [weak self] _ in self?.handleCandidate() }
        monitor.onDismiss = { [weak self] in self?.dismiss() }
        monitor.isPopupVisible = { [weak self] in self?.panel.isShowing ?? false }
        panel.model.onSelect = { [weak self] action in self?.perform(action) }
        panel.model.onCardActivate = { [weak self] in self?.activateCard() }
        panel.model.onCardCopy = { [weak self] in self?.copyCard() }
        panel.model.onCardClose = { [weak self] in self?.dismiss() }
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
        let available = PopupAction.available(manager.popupActions(), for: info)
        guard !available.isEmpty else {
            panel.dismiss()
            return
        }
        selection = info
        panel.present(actions: available, anchor: anchor, side: placement.side(for: app.bundleIdentifier))
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
            panel.model.runningID = nil
            // The action put text on screen (showText): leave it there.
            if panel.model.card != nil { return }
            if case .failure(let message) = outcome { NSLog("PopKit: \(action.title) failed: \(message)") }
            panel.model.result = outcome
            try? await Task.sleep(nanoseconds: 700_000_000)
            if current == generation { dismiss() }
        }
    }

    // MARK: Text cards

    /// Click on a preview: paste over the selection when it is editable, otherwise copy.
    private func activateCard() {
        guard let card = panel.model.card else { return }
        let current = generation
        if card.canPaste {
            Task {
                await Paster.paste(card.text, restore: true)
                if current == generation { dismiss() }
            }
        } else {
            Paster.copy(card.text)
            finishCard(current)
        }
    }

    private func copyCard() {
        guard let card = panel.model.card else { return }
        Paster.copy(card.text)
        finishCard(generation)
    }

    /// ✓ for a moment, then close.
    private func finishCard(_ current: Int) {
        panel.model.card = nil
        panel.model.result = .success
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if current == generation { dismiss() }
        }
    }

    // MARK: ExtensionHost

    func pasteText(_ text: String, restore: Bool) async {
        await Paster.paste(text, restore: restore)
    }

    func copyText(_ text: String) {
        Paster.copy(text)
    }

    func showText(_ text: String, style: ShowTextStyle) {
        guard panel.isShowing else { return }
        panel.model.runningID = nil
        panel.model.card = TextCard(
            text: text, style: style, canPaste: style == .preview && (selection?.isEditable ?? false))
        if style == .plain {
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, current == self.generation else { return }
                self.dismiss()
            }
        }
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openSettings(forExtension id: String) {
        onOpenSettings?(id)
    }
}
