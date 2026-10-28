import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class SSHQuickConnectModel: ObservableObject {
    enum Action: Equatable {
        case connect(SSHHostReference)
        case connectInSplit(SSHHostReference)
    }

    @Published var query = "" {
        didSet { clampSelection() }
    }
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var hosts: [SSHHostEntry]
    @Published private var recentReferences: [SSHHostReference]

    init(hosts: [SSHHostEntry], recentReferences: [SSHHostReference] = []) {
        self.hosts = hosts
        self.recentReferences = recentReferences
        selectedIndex = nil
        clampSelection()
    }

    var entries: [SSHHostEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entriesWithRecentsFirst() }

        return hosts.filter { entry in
            ([entry.reference.alias] + entry.siblingAliases).contains { $0.localizedCaseInsensitiveContains(query) } ||
                entry.displayName?.localizedCaseInsensitiveContains(query) == true ||
                entry.resolved?.display.localizedCaseInsensitiveContains(query) == true
        }
    }

    var selectedEntry: SSHHostEntry? {
        guard let selectedIndex, entries.indices.contains(selectedIndex) else {
            return nil
        }
        return entries[selectedIndex]
    }

    func updateHosts(_ hosts: [SSHHostEntry]) {
        self.hosts = hosts
        clampSelection()
    }

    func updateRecentReferences(_ references: [SSHHostReference]) {
        recentReferences = references
        clampSelection()
    }

    func moveSelection(by offset: Int) {
        guard !entries.isEmpty else {
            selectedIndex = nil
            return
        }

        let current = selectedIndex ?? 0
        selectedIndex = min(max(current + offset, 0), entries.count - 1)
    }

    func select(_ entry: SSHHostEntry) {
        selectedIndex = entries.firstIndex(where: { $0.reference == entry.reference })
    }

    func action(connectInSplit: Bool) -> Action? {
        guard let reference = selectedEntry?.reference else { return nil }
        return connectInSplit ? .connectInSplit(reference) : .connect(reference)
    }

    private func entriesWithRecentsFirst() -> [SSHHostEntry] {
        var byReference: [SSHHostReference: SSHHostEntry] = [:]
        for entry in hosts {
            byReference[entry.reference] = entry
        }
        var seen = Set<SSHHostReference>()
        var ordered: [SSHHostEntry] = []

        for reference in recentReferences {
            guard seen.insert(reference).inserted, let entry = byReference[reference] else {
                continue
            }
            ordered.append(entry)
        }

        ordered += hosts.filter { seen.insert($0.reference).inserted }
        return ordered
    }

    private func clampSelection() {
        guard !entries.isEmpty else {
            selectedIndex = nil
            return
        }
        selectedIndex = min(max(selectedIndex ?? 0, 0), entries.count - 1)
    }
}

struct SSHQuickConnectPopover: View {
    let capability: SSHCapability
    let dismiss: () -> Void

    @ObservedObject private var catalog: SSHHostCatalog
    @ObservedObject private var services: SSHServices
    @ObservedObject private var tunnels: SSHTunnelController
    @StateObject private var model: SSHQuickConnectModel

    init(capability: SSHCapability, dismiss: @escaping () -> Void) {
        self.capability = capability
        self.dismiss = dismiss
        _catalog = ObservedObject(wrappedValue: capability.services.catalog)
        _services = ObservedObject(wrappedValue: capability.services)
        _tunnels = ObservedObject(wrappedValue: capability.services.tunnels)
        _model = StateObject(wrappedValue: SSHQuickConnectModel(
            hosts: capability.services.catalog.snapshot.entries,
            recentReferences: capability.services.recentReferences))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSHQuickConnectSearchField(
                query: $model.query,
                submit: { performSelected(connectInSplit: $0) },
                move: { model.moveSelection(by: $0) },
                cancel: dismiss)
                .padding(12)

            if model.entries.isEmpty {
                Text("No matching hosts")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            hostRow(entry, selected: index == model.selectedIndex)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack {
                Text("↩ New Tab · ⌥↩ Split Right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)

            if !tunnels.definitions.isEmpty {
                Divider()
                tunnelSection
            }

            Divider()
            Button("Manage SSH Hosts…") {
                dismiss()
                capability.showHosts()
            }
            .accessibilityIdentifier("ssh.manage-hosts")
            .padding(12)
        }
        .frame(width: 340)
        .onReceive(catalog.$snapshot) { updateCatalog(snapshot: $0) }
        .onReceive(services.$recentReferences) { model.updateRecentReferences($0) }
    }

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tunnels")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            ForEach(tunnels.definitions) { definition in
                tunnelRow(definition)
            }
        }
        .padding(.bottom, 4)
    }

    private func tunnelRow(_ definition: SSHTunnelDefinition) -> some View {
        let phase = tunnels.manager.phase(for: definition.id)
        let blocker = tunnels.startBlocker(for: definition)
        return HStack(spacing: 8) {
            Circle()
                .fill(SSHTunnelStatusColor.color(for: phase))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.name)
                Text(blocker.map { _ in SSHTunnelController.specification(of: definition) }
                    ?? "\(SSHTunnelController.status(for: phase)) · \(SSHTunnelController.specification(of: definition))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let blocker, !tunnels.isRunning(definition.id) {
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if tunnels.isRunning(definition.id) {
                Button("Stop") { capability.stopTunnel(definition.id) }
            } else {
                Button("Start") { capability.startTunnel(definition.id) }
                    .disabled(blocker != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func hostRow(_ entry: SSHHostEntry, selected: Bool) -> some View {
        Button {
            model.select(entry)
            performSelected(connectInSplit: false)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName ?? entry.reference.alias)
                    Text(entry.resolved?.display ?? entry.reference.alias)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Text("↩")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
        .accessibilityLabel(accessibilityLabel(for: entry))
        .accessibilityHint("Press Return to open in a new tab")
    }

    private func updateCatalog(snapshot: SSHConfigScanResult) {
        capability.services.removeUnavailableRecentReferences(using: snapshot.entries)
        model.updateHosts(snapshot.entries)
    }

    private func performSelected(connectInSplit: Bool) {
        guard let action = model.action(connectInSplit: connectInSplit) else { return }

        switch action {
        case .connect(let reference):
            capability.connect(reference, inSplit: false)
        case .connectInSplit(let reference):
            capability.connect(reference, inSplit: true)
        }
        dismiss()
    }

    private func accessibilityLabel(for entry: SSHHostEntry) -> String {
        let name = entry.displayName ?? entry.reference.alias
        guard let destination = entry.resolved?.display else { return name }
        return "\(name), \(destination)"
    }
}

/// Handle Return in the field editor, before Option-Return can insert a newline.
private struct SSHQuickConnectSearchField: NSViewRepresentable {
    @Binding var query: String
    let submit: (Bool) -> Void
    let move: (Int) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Connect to host…"
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        // Editing owns the field editor's text, including IME composition.
        if field.currentEditor() == nil, field.stringValue != query {
            field.stringValue = query
        }
    }

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SSHQuickConnectSearchField

        init(_ parent: SSHQuickConnectSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit(NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.submit(true)
            case #selector(NSResponder.moveUp(_:)):
                parent.move(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.move(1)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.cancel()
            default:
                return false
            }
            return true
        }
    }
}
