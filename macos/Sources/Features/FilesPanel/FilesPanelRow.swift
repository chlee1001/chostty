import SwiftUI

struct FilesPanelRow: View {
    let node: FilesPanelNode
    let root: String
    let onOpen: () -> Void
    let onToggleDirectory: () -> Void
    let onQuickLook: () -> Void
    let onPastePath: () -> Void
    let onOpenNewTab: () -> Void

    var body: some View {
        Button(action: node.isDirectory ? onToggleDirectory : onOpen) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(node.isDirectory ? .secondary : .primary)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("files-panel-row-\(node.path)")
        .contextMenu {
            if !node.isDirectory {
                Button("Preview with Quick Look", action: onQuickLook)
            }
            Button("Open in Default App") { FilesPanelFileActions.openInDefaultApp(path: node.path) }
            Button("Reveal in Finder") { FilesPanelFileActions.revealInFinder(path: node.path) }
            Divider()
            Button("Copy Absolute Path") { FilesPanelFileActions.copyAbsolutePath(node.path) }
            Button("Copy Relative Path") { FilesPanelFileActions.copyRelativePath(node.path, root: root) }
            Button("Paste Path into Terminal", action: onPastePath)
            Button("Open Directory in New Tab", action: onOpenNewTab)
        }
    }

    private var iconName: String {
        switch node.kind {
        case .directory:
            if case .loaded = node.children { return "folder.fill" }
            return "folder"
        case .file: return "doc"
        case .symbolicLink: return "link"
        }
    }
}
