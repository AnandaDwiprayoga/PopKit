import AppKit
import PopKitCore
import SwiftUI

struct ExtensionsTab: View {
    @ObservedObject var model: SettingsModel

    private var selected: InstalledExtension? {
        model.extensions.first { $0.id == model.selectedExtensionID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selectedExtensionID) {
                    ForEach(model.extensions) { ext in
                        ExtensionRow(model: model, ext: ext).tag(ext.id)
                    }
                    .onMove(perform: model.moveExtensions)
                }
                Divider()
                HStack {
                    Button("Install…") { model.onInstallRequest?() }
                    Spacer()
                    Button {
                        if let ext = selected { remove(ext) }
                    } label: { Image(systemName: "minus") }
                        .disabled(selected == nil || selected?.isBundled == true)
                        .help("Remove the selected extension")
                }
                .padding(8)
            }
            .frame(width: 220)

            Divider()

            Group {
                if let ext = selected {
                    ExtensionDetail(model: model, ext: ext).id(ext.id)
                } else {
                    Text("Select an extension").foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if model.selectedExtensionID == nil { model.selectedExtensionID = model.extensions.first?.id }
        }
    }

    private func remove(_ ext: InstalledExtension) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(ext.manifest.name)”?"
        alert.informativeText = "Its saved settings, including any API key, are deleted too."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.manager.remove(ext.id)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct ExtensionRow: View {
    @ObservedObject var model: SettingsModel
    let ext: InstalledExtension

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { model.manager.store.isEnabled(ext.id) },
                set: { model.manager.setEnabled($0, id: ext.id) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            IconView(icon: ext.manifest.icon ?? "•", size: 14).frame(width: 20)
            Text(ext.manifest.name).lineLimit(1)
        }
    }
}

private struct ExtensionDetail: View {
    @ObservedObject var model: SettingsModel
    let ext: InstalledExtension

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IconView(icon: ext.manifest.icon ?? "•", size: 22).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ext.manifest.name).font(.title3).bold()
                        HStack(spacing: 6) {
                            if ext.isBundled { Tag(text: "Built-in", systemImage: "shippingbox") }
                            if ext.manifest.allowsNetwork { Tag(text: "Uses the network", systemImage: "network") }
                        }
                    }
                }
                if let description = ext.manifest.description {
                    Text(description).font(.callout).foregroundColor(.secondary)
                }

                if let error = model.manager.loadError(for: ext.id) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundColor(.orange)
                }

                if !ext.manifest.options.isEmpty {
                    OptionsForm(ext: ext, options: model.manager.options)
                }

                LogView(log: model.manager.log(for: ext.id))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Tag: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

/// One field per option in Config.json: text, password (Keychain), picker or toggle.
private struct OptionsForm: View {
    let ext: InstalledExtension
    let options: OptionsStore
    @State private var values: [String: OptionValue]

    init(ext: InstalledExtension, options: OptionsStore) {
        self.ext = ext
        self.options = options
        _values = State(initialValue: options.values(for: ext.manifest, extensionID: ext.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ext.manifest.options) { spec in
                VStack(alignment: .leading, spacing: 3) {
                    field(spec)
                    if let description = spec.description {
                        Text(description).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func binding(_ spec: OptionSpec) -> Binding<OptionValue> {
        Binding(
            get: { values[spec.identifier] ?? spec.effectiveDefault },
            set: {
                values[spec.identifier] = $0
                options.set($0, for: spec, extensionID: ext.id)
            })
    }

    private func text(_ spec: OptionSpec) -> Binding<String> {
        let value = binding(spec)
        return Binding(get: { value.wrappedValue.stringValue }, set: { value.wrappedValue = .string($0) })
    }

    @ViewBuilder private func field(_ spec: OptionSpec) -> some View {
        switch spec.kind {
        case .string:
            LabeledContent(spec.label) { TextField("", text: text(spec)).textFieldStyle(.roundedBorder) }
        case .secret:
            LabeledContent(spec.label) { SecureField("", text: text(spec)).textFieldStyle(.roundedBorder) }
        case .multiple:
            Picker(spec.label, selection: text(spec)) {
                ForEach(spec.values, id: \.self) { Text(spec.displayLabel(forValue: $0)).tag($0) }
            }
        case .boolean:
            Toggle(spec.label, isOn: Binding(
                get: { binding(spec).wrappedValue.boolValue },
                set: { binding(spec).wrappedValue = .bool($0) }))
        }
    }
}

private struct LogView: View {
    @ObservedObject var log: ExtensionLog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { log.clear() }.disabled(log.lines.isEmpty)
            }
            ScrollView {
                Text(log.lines.isEmpty ? "Nothing logged yet." : log.lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(log.lines.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(height: 110)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
