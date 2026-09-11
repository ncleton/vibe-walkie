import SwiftUI
import PhotosUI
import RemoteCore
import UIKit

struct ControlConfiguratorView: View {
    @EnvironmentObject private var client: HostConnectionClient
    @State private var selectedZone: ControlZone?
    @State private var showResetConfirmation = false
    @State private var showGlobalOrder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ios.button.panel.39e8512")
                        .font(.title2.bold())
                    Text("ios.tap.a.position.to.choose.its.key.name.and.icon.c579601")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ControlLayoutEditorPreview(configuration: client.controlConfiguration) { zone in
                    selectedZone = zone
                }

                Button {
                    showGlobalOrder = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.grid.2x2.fill")
                            .font(.title3)
                            .foregroundStyle(Color.remoteBlue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ios.global.bubble.d8b1205")
                                .font(.headline)
                            Text("ios.reorder.hidden.controls.6460b74")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: -4) {
                            ForEach(client.controlConfiguration.availableGlobalButtons.prefix(4)) { button in
                                ControlIconImage(icon: button.icon)
                                    .frame(width: 14, height: 14)
                                    .padding(7)
                                    .background(Color.controlSurface, in: Circle())
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                Label {
                    Text(LocalizedStringKey(client.state.isReady
                                            ? "ios.changes.sync.ready"
                                            : "ios.changes.sync.pending"))
                } icon: {
                    Image(systemName: client.state.isReady ? "arrow.triangle.2.circlepath" : "clock.arrow.circlepath")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("ios.mac.shortcuts.6f27118")
                        .font(.headline)
                    Text("ios.on.iphone.you.can.assign.standard.keys.to.record.any.d48ee16")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button("ios.restore.original.buttons.06b187d", role: .destructive) {
                    showResetConfirmation = true
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("ios.controls.0e3118a")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedZone) { zone in
            NavigationStack {
                IOSControlButtonEditor(
                    button: client.controlConfiguration.button(in: zone),
                    availableShortcuts: client.controlConfiguration.availableShortcuts ?? []
                ) { button in
                    var configuration = client.controlConfiguration
                    configuration.setButton(button)
                    client.updateControlConfiguration(configuration)
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showGlobalOrder) {
            NavigationStack {
                GlobalButtonOrderView(
                    configuration: client.controlConfiguration,
                    save: { order in
                        client.updateGlobalButtonSlots(order.map(Optional.some))
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "ios.reset.button.panel.e2995ec",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("ios.restore.original.buttons.e9f294f", role: .destructive) {
                client.resetControlConfiguration()
            }
            Button("ios.cancel.46ad391", role: .cancel) {}
        } message: {
            Text("ios.custom.shortcuts.and.icons.in.these.seven.positions.will.be.6fa78be")
        }
    }
}

private struct GlobalButtonOrderView: View {
    @Environment(\.dismiss) private var dismiss
    let configuration: ControlConfiguration
    let save: ([GlobalButtonConfiguration]) -> Void
    @State private var order: [GlobalButtonConfiguration]

    init(configuration: ControlConfiguration, save: @escaping ([GlobalButtonConfiguration]) -> Void) {
        self.configuration = configuration
        self.save = save
        _order = State(initialValue: configuration.availableGlobalButtons)
    }

    var body: some View {
        List {
            Section {
                ForEach(order) { button in
                    HStack(spacing: 12) {
                        ControlIconImage(icon: button.icon)
                            .frame(width: 20, height: 20)
                            .frame(width: 36, height: 36)
                            .background(Color.remoteBlue.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ControlTitleLocalization.title(button.title, action: button.action))
                                .font(.body.weight(.semibold))
                            Text(button.action.globalDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { offsets, destination in
                    order.move(fromOffsets: offsets, toOffset: destination)
                    save(order)
                }
            } header: {
                Text("ios.hold.the.handle.then.drag.35697e0")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("ios.global.order.3df30ee")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("ios.done.f28acc8") { dismiss() }
            }
        }
    }
}

private struct ControlLayoutEditorPreview: View {
    let configuration: ControlConfiguration
    let select: (ControlZone) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                sideColumn([.upperLeft, .lowerLeft])

                VStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 88)
                        .background(Color.remoteBlue, in: Circle())
                    Label("ios.ptt.locked.c9954d7", systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                sideColumn([.upperRight, .lowerRight])
            }

            HStack(spacing: 8) {
                zoneButton(.bottomLeft)
                zoneButton(.bottomCenter)
                zoneButton(.bottomRight)
            }
        }
        .padding(14)
        .background(Color.controlSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func sideColumn(_ zones: [ControlZone]) -> some View {
        VStack(spacing: 8) {
            ForEach(zones) { zone in zoneButton(zone) }
        }
        .frame(maxWidth: .infinity)
    }

    private func zoneButton(_ zone: ControlZone) -> some View {
        let button = configuration.button(in: zone)
        return Button { select(zone) } label: {
            VStack(spacing: 5) {
                ControlIconImage(icon: button.icon)
                    .frame(width: 22, height: 22)
                Text(ControlTitleLocalization.title(button.title, action: button.action))
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.remoteBlue)
                    .padding(5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppL10n.format("ios.edit.value.9465aba", ControlTitleLocalization.title(button.title, action: button.action)))
    }
}

private struct IOSControlButtonEditor: View {
    private enum ActionChoice: String, CaseIterable, Identifiable {
        case standard
        case showKeyboard
        case none
        case macShortcut

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let original: ControlButtonConfiguration
    let availableShortcuts: [HostShortcutReference]
    let save: (ControlButtonConfiguration) -> Void

    @State private var title: String
    @State private var icon: ControlButtonIcon
    @State private var actionChoice: ActionChoice
    @State private var standardKey: RemoteKey
    @State private var retainedHostShortcut: HostShortcutReference?
    @State private var selectedHostShortcutID: String?
    @State private var photoItem: PhotosPickerItem?

    init(
        button: ControlButtonConfiguration,
        availableShortcuts: [HostShortcutReference],
        save: @escaping (ControlButtonConfiguration) -> Void
    ) {
        original = button
        self.availableShortcuts = availableShortcuts
        self.save = save
        _title = State(initialValue: ControlTitleLocalization.title(button.title, action: button.action))
        _icon = State(initialValue: button.icon)

        switch button.action {
        case .standardKey(let key):
            _actionChoice = State(initialValue: .standard)
            _standardKey = State(initialValue: key)
            _retainedHostShortcut = State(initialValue: nil)
            _selectedHostShortcutID = State(initialValue: nil)
        case .showKeyboard:
            _actionChoice = State(initialValue: .showKeyboard)
            _standardKey = State(initialValue: .enter)
            _retainedHostShortcut = State(initialValue: nil)
            _selectedHostShortcutID = State(initialValue: nil)
        case .hostShortcut(let shortcut):
            _actionChoice = State(initialValue: .macShortcut)
            _standardKey = State(initialValue: .enter)
            _retainedHostShortcut = State(initialValue: shortcut)
            _selectedHostShortcutID = State(initialValue: shortcut.id)
        case .macShortcut(let shortcut):
            _actionChoice = State(initialValue: .macShortcut)
            _standardKey = State(initialValue: .enter)
            _retainedHostShortcut = State(initialValue: shortcut.migratedDefinition.reference)
            _selectedHostShortcutID = State(initialValue: shortcut.migratedDefinition.reference.id)
        case .none:
            _actionChoice = State(initialValue: .none)
            _standardKey = State(initialValue: .enter)
            _retainedHostShortcut = State(initialValue: nil)
            _selectedHostShortcutID = State(initialValue: nil)
        }
    }

    var body: some View {
        Form {
            Section("ios.position.a8a06e4") {
                LabeledContent("ios.position.bd92a6d", value: original.zone.localizedName)
                TextField("ios.button.name.0386b44", text: $title)
                    .textInputAutocapitalization(.sentences)
            }

            Section("ios.action.64cff13") {
                Picker("ios.type.baaddf7", selection: $actionChoice) {
                    Text("ios.standard.key.c5f1c34").tag(ActionChoice.standard)
                    Text("ios.show.keyboard.d82ba3f").tag(ActionChoice.showKeyboard)
                    Text("ios.no.action.ec3e8c2").tag(ActionChoice.none)
                    if !shortcutChoices.isEmpty {
                        Text("ios.shortcut.saved.on.the.mac.fb25886").tag(ActionChoice.macShortcut)
                    }
                }

                if actionChoice == .standard {
                    Picker("ios.key.67754b1", selection: $standardKey) {
                        ForEach(RemoteKey.allCases, id: \.self) { key in
                            Label(key.localizedName, systemImage: key.suggestedSystemImage)
                                .tag(key)
                        }
                    }
                } else if actionChoice == .macShortcut, !shortcutChoices.isEmpty {
                    Picker("ios.combination.151b519", selection: $selectedHostShortcutID) {
                        ForEach(shortcutChoices) { shortcut in
                            Label(shortcut.displayName, systemImage: shortcut.icon ?? "command")
                                .tag(Optional(shortcut.id))
                        }
                    }
                    Text("ios.this.hardware.shortcut.can.be.replaced.from.the.mac.add59c8")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("ios.icon.09e8677") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(ControlIconCatalog.systemImages, id: \.self) { name in
                        Button {
                            icon = .system(name)
                        } label: {
                            Image(systemName: name)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(isSelected(name) ? Color.remoteBlue : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("ios.import.another.icon.fc4f9ae", systemImage: "photo.badge.plus")
                }
            }
        }
        .navigationTitle("ios.edit.button.7e82cc8")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("ios.cancel.46ad391") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("ios.save.71dc748") {
                    save(ControlButtonConfiguration(
                        zone: original.zone,
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Sans titre" : title,
                        icon: icon,
                        action: selectedAction
                    ))
                    dismiss()
                }
            }
        }
        .task(id: photoItem) {
            guard let data = try? await photoItem?.loadTransferable(type: Data.self),
                  let normalized = IconImageNormalizer.normalizedData(from: data) else { return }
            icon = .customImage(normalized)
        }
    }

    private var selectedAction: ControlButtonAction {
        switch actionChoice {
        case .standard: return .standardKey(standardKey)
        case .showKeyboard: return .showKeyboard
        case .none: return .none
        case .macShortcut:
            let shortcut = shortcutChoices.first { $0.id == selectedHostShortcutID } ?? retainedHostShortcut
            return shortcut.map(ControlButtonAction.hostShortcut) ?? .none
        }
    }

    private var shortcutChoices: [HostShortcutReference] {
        var seen = Set<String>()
        return (availableShortcuts + [retainedHostShortcut].compactMap { $0 })
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func isSelected(_ name: String) -> Bool {
        guard case .system(let selected) = icon else { return false }
        return selected == name
    }
}

struct ControlIconImage: View {
    let icon: ControlButtonIcon

    var body: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
        case .customImage(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
            }
        }
    }
}

enum ControlIconCatalog {
    static let systemImages = [
        "keyboard", "return", "space", "delete.left", "escape", "tab.key",
        "command", "option", "control", "shift", "globe", "fn",
        "arrow.up", "arrow.down", "arrow.left", "arrow.right", "arrow.uturn.backward",
        "doc.on.doc", "doc.on.clipboard", "scissors", "magnifyingglass", "square.and.arrow.up",
        "play.fill", "pause.fill", "backward.fill", "forward.fill", "speaker.wave.2.fill",
        "mic.fill", "camera.fill", "lock.fill", "moon.fill", "sun.max.fill",
        "app", "rectangle.on.rectangle", "arrow.left.arrow.right", "plus", "star.fill"
    ]
}

private enum IconImageNormalizer {
    static func normalizedData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (size.width - target.width) / 2,
                y: (size.height - target.height) / 2,
                width: target.width,
                height: target.height
            ))
        }
        guard let png = rendered.pngData(), png.count <= 40 * 1_024 else {
            guard let jpeg = rendered.jpegData(compressionQuality: 0.72), jpeg.count <= 40 * 1_024 else {
                guard let compact = rendered.jpegData(compressionQuality: 0.45), compact.count <= 40 * 1_024 else {
                    return nil
                }
                return compact
            }
            return jpeg
        }
        return png
    }
}

extension ControlZone {
    var localizedName: String {
        switch self {
        case .upperLeft: return AppL10n.text("ios.upper.left.a8899ea")
        case .lowerLeft: return AppL10n.text("ios.lower.left.7ffbd14")
        case .upperRight: return AppL10n.text("ios.upper.right.f2b9c7b")
        case .lowerRight: return AppL10n.text("ios.lower.right.77181d6")
        case .bottomLeft: return AppL10n.text("ios.bottom.row.left.4544c19")
        case .bottomCenter: return AppL10n.text("ios.bottom.row.center.e5b8187")
        case .bottomRight: return AppL10n.text("ios.bottom.row.right.c83635a")
        }
    }
}

extension RemoteKey {
    var localizedName: String {
        switch self {
        case .enter: return AppL10n.text("ios.return.d9c7efe")
        case .escape: return AppL10n.text("ios.esc.7bd72d1")
        case .tab: return AppL10n.text("ios.tab.40d4558")
        case .applicationSwitcher: return AppL10n.text("ios.previous.app.5711d90")
        case .nextConversation: return AppL10n.text("ios.next.488d1ea")
        case .backspace: return AppL10n.text("ios.backspace.ff7e715")
        case .delete: return AppL10n.text("ios.delete.5e5d021")
        case .arrowUp: return AppL10n.text("ios.up.4260ca3")
        case .arrowDown: return AppL10n.text("ios.down.686b88e")
        case .arrowLeft: return AppL10n.text("ios.left.b107a0a")
        case .arrowRight: return AppL10n.text("ios.right.37f370d")
        case .space: return AppL10n.text("ios.space.91bdaf6")
        case .copy: return AppL10n.text("ios.copy.f84a10c")
        case .paste: return AppL10n.text("ios.paste.39f83c7")
        case .cut: return AppL10n.text("ios.cut.c0be34a")
        }
    }

    var suggestedSystemImage: String {
        switch self {
        case .enter: return "return"
        case .escape: return "escape"
        case .tab: return "arrow.right.to.line"
        case .applicationSwitcher: return "arrow.left.arrow.right"
        case .nextConversation: return "arrow.right.to.line"
        case .backspace: return "delete.left"
        case .delete: return "delete.right"
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        case .space: return "space"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .cut: return "scissors"
        }
    }
}

private extension ControlButtonAction {
    var globalDescription: String {
        switch self {
        case .none: return AppL10n.text("ios.not.configured.3c454da")
        case .standardKey(let key): return key.localizedName
        case .hostShortcut(let shortcut): return shortcut.displayName
        case .macShortcut(let shortcut): return shortcut.displayName
        case .showKeyboard: return AppL10n.text("ios.iphone.keyboard.df50452")
        }
    }
}
