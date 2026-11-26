import AppKit
import Combine
import PopKitCore
import SwiftUI

@MainActor
final class PopupModel: ObservableObject {
    @Published var actions: [PopupAction] = []
    /// The action whose button shows a spinner.
    @Published var runningID: String?
    /// Set briefly after an action finishes: the bar shows ✓ or ✗.
    @Published var result: ActionOutcome?

    var onSelect: ((PopupAction) -> Void)?

    func reset() {
        actions = []
        runningID = nil
        result = nil
    }
}

/// A floating bar that never takes focus, so the app you selected in keeps its selection,
/// which is what ⌘V needs to replace it.
@MainActor
final class PopupPanel: NSPanel {
    let model = PopupModel()

    private var hosting: NSHostingView<PopupView>!
    private var anchor: CGRect = .zero
    private var side: PopupSide = .above
    private var changes: AnyCancellable?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        hosting = NSHostingView(rootView: PopupView(model: model))
        contentView = hosting

        // Re-fit after the content changes (spinner, ✓).
        changes = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refit() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isShowing: Bool { isVisible }

    func present(actions: [PopupAction], anchor: CGRect, side: PopupSide) {
        model.runningID = nil
        model.result = nil
        model.actions = actions
        self.anchor = anchor
        self.side = side
        refit()
        orderFrontRegardless()
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        model.reset()
    }

    private func refit() {
        guard !model.actions.isEmpty || model.result != nil else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrame(PopupPlacement.frame(size: size, anchor: anchor, visible: visible, preferred: side), display: true)
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel

    var body: some View {
        HStack(spacing: 2) {
            if let result = model.result {
                Text(result.isSuccess ? "✓" : "✗")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(result.isSuccess ? .green : .red)
                    .frame(width: 30, height: 28)
            } else {
                ForEach(model.actions) { action in
                    ActionButton(action: action, isRunning: model.runningID == action.id) {
                        model.onSelect?(action)
                    }
                }
            }
        }
        .padding(4)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

private struct ActionButton: View {
    let action: PopupAction
    let isRunning: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    icon
                }
            }
            .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.title)
    }

    @ViewBuilder private var icon: some View {
        let symbolPrefix = "symbol:"
        if action.icon.hasPrefix(symbolPrefix) {
            Image(systemName: String(action.icon.dropFirst(symbolPrefix.count)))
                .font(.system(size: 14))
        } else {
            Text(action.icon).font(.system(size: 15))
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
