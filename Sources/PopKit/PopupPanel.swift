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
    /// Text from `popclip.showText`, shown in place of the buttons.
    @Published var card: TextCard?

    var onSelect: ((PopupAction) -> Void)?
    var onCardActivate: (() -> Void)?
    var onCardCopy: (() -> Void)?
    var onCardClose: (() -> Void)?

    func reset() {
        actions = []
        runningID = nil
        result = nil
        card = nil
    }
}

struct TextCard: Equatable {
    var text: String
    var style: ShowTextStyle
    /// A preview in an editable field pastes when clicked. Otherwise it copies.
    var canPaste: Bool
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
        model.card = nil
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
        guard !model.actions.isEmpty || model.result != nil || model.card != nil else { return }
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
            if let card = model.card {
                CardView(model: model, card: card)
            } else if let result = model.result {
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
                    IconView(icon: action.icon)
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
}

/// An extension icon: `symbol:<SF Symbol>`, `file:<path to a PNG>`, or an emoji or short text.
struct IconView: View {
    let icon: String
    var size: CGFloat = 15

    var body: some View {
        if icon.hasPrefix("symbol:") {
            Image(systemName: String(icon.dropFirst("symbol:".count)))
                .font(.system(size: size - 1))
        } else if icon.hasPrefix("file:"), let image = NSImage(contentsOfFile: String(icon.dropFirst("file:".count))) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size + 3, height: size + 3)
        } else {
            Text(icon).font(.system(size: size))
        }
    }
}

/// Text from `popclip.showText`.
private struct CardView: View {
    @ObservedObject var model: PopupModel
    let card: TextCard

    var body: some View {
        switch card.style {
        case .plain:
            Text(card.text)
                .font(.system(size: 12))
                .lineLimit(3)
                .frame(maxWidth: 320)
                .padding(.horizontal, 8).padding(.vertical, 6)
        case .preview:
            Button { model.onCardActivate?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: card.canPaste ? "arrow.down.doc" : "doc.on.doc")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    Text(card.text)
                        .font(.system(size: 12))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 340, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(card.canPaste ? "Click to paste" : "Click to copy")
        case .large:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(card.text)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 400, height: 200)
                HStack {
                    Button("Copy") { model.onCardCopy?() }
                    Spacer()
                    Button("Close") { model.onCardClose?() }
                }
            }
            .padding(10)
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
