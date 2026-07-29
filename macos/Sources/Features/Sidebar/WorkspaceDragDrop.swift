import SwiftUI
import UniformTypeIdentifiers

/// What a sidebar/tab-strip drag is carrying.
///
/// Drags are identified by UUID rather than by index: the list re-renders
/// during a drag, so an index captured at drag start can point at a different
/// row by the time the drop lands.
enum WorkspaceDragPayload: Equatable {
    case tab(UUID)
    case workspace(UUID)

    private static let tabPrefix = "chostty.tab:"
    private static let workspacePrefix = "chostty.workspace:"

    var stringValue: String {
        switch self {
        case .tab(let id): return Self.tabPrefix + id.uuidString
        case .workspace(let id): return Self.workspacePrefix + id.uuidString
        }
    }

    init?(stringValue: String) {
        if stringValue.hasPrefix(Self.tabPrefix),
           let id = UUID(uuidString: String(stringValue.dropFirst(Self.tabPrefix.count))) {
            self = .tab(id)
        } else if stringValue.hasPrefix(Self.workspacePrefix),
                  let id = UUID(uuidString: String(stringValue.dropFirst(Self.workspacePrefix.count))) {
            self = .workspace(id)
        } else {
            return nil
        }
    }

    var itemProvider: NSItemProvider {
        NSItemProvider(object: stringValue as NSString)
    }
}

/// Reorder drag/drop for a row.
///
/// Uses `draggable`/`dropDestination` rather than `onDrag`/`onDrop`. The older
/// `onDrop(of:delegate:)` registers an AppKit drag destination eagerly during
/// view setup, which deadlocks the XCTest host before it can establish its
/// connection. The Transferable-based API registers lazily and does not.
extension View {
    func workspaceReorderable(
        payload: WorkspaceDragPayload,
        dropTarget: Binding<WorkspaceDragPayload?>,
        onDrop: @escaping (WorkspaceDragPayload, WorkspaceDragPayload) -> Void
    ) -> some View {
        self
            .draggable(payload.stringValue)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let source = WorkspaceDragPayload(stringValue: raw),
                      source != payload else { return false }
                onDrop(source, payload)
                return true
            } isTargeted: { targeted in
                // Only hold the highlight while actually hovered, so a drag that
                // ends elsewhere does not leave a stale insertion indicator.
                if targeted {
                    dropTarget.wrappedValue = payload
                } else if dropTarget.wrappedValue == payload {
                    dropTarget.wrappedValue = nil
                }
            }
    }
}

/// Inline rename field used by both the sidebar and the tab strip.
///
/// Commits on Return or focus loss and cancels on Escape, matching how Finder
/// and Xcode handle inline renaming.
struct InlineRenameField: View {
    @Binding var text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .focused($focused)
            .onSubmit { onCommit(text) }
            .onExitCommand { onCancel() }
            .onAppear { focused = true }
            .onChange(of: focused) { isFocused in
                // Losing focus commits, so clicking elsewhere keeps the edit
                // rather than silently discarding it.
                if !isFocused { onCommit(text) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.12)))
    }
}

/// Color picker rows shared by the workspace and tab context menus.
struct TabColorMenuItems: View {
    let current: TerminalTabColor
    let onPick: (TerminalTabColor) -> Void

    var body: some View {
        ForEach(TerminalTabColor.allCases, id: \.rawValue) { color in
            Button {
                onPick(color)
            } label: {
                if color == current {
                    Label(color.localizedName, systemImage: "checkmark")
                } else {
                    Text(color.localizedName)
                }
            }
        }
    }
}

extension TerminalTabColor {
    /// Parses the string form stored on `TerminalSessionState.tabColor`.
    static func fromStored(_ raw: String?) -> TerminalTabColor {
        guard let raw, let value = Int(raw), let color = TerminalTabColor(rawValue: value) else {
            return .none
        }
        return color
    }

    /// SwiftUI color for tinting sidebar rows and tab-strip items.
    var swiftUIColor: Color? {
        guard let ns = displayColor else { return nil }
        return Color(nsColor: ns)
    }
}
