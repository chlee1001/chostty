import SwiftUI

struct FilesPanelView: View {
    @ObservedObject var controller: FilesPanelController
    @ObservedObject private var treeViewModel: FilesPanelTreeViewModel
    let terminalController: TerminalController?
    let readerStore: TerminalReaderStore?
    @StateObject private var quickLook = FilesPanelQuickLookCoordinator()

    init(
        controller: FilesPanelController,
        terminalController: TerminalController?,
        readerStore: TerminalReaderStore?
    ) {
        self.controller = controller
        self.terminalController = terminalController
        self.readerStore = readerStore
        treeViewModel = controller.treeViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TextField("Filter Files", text: $treeViewModel.filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .accessibilityIdentifier("files-panel-filter")
            content
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-panel")
        .background(FilesPanelQuickLookResponderView {
            guard let path = readerStore?.current?.sourcePath else { return false }
            quickLook.toggleSpaceAction(url: URL(fileURLWithPath: path))
            return true
        })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            Text(controller.currentRoot.map {
                FilesPanelPathFormatting.abbreviatedPath($0)
            } ?? "Files")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                if controller.presentation.rootMode == .pinned {
                    controller.followPWD()
                } else if let root = controller.currentRoot {
                    controller.pin(root: root)
                }
            } label: {
                Image(systemName: controller.presentation.rootMode == .pinned ? "pin.fill" : "pin")
            }
            .help(controller.presentation.rootMode == .pinned ? "Follow Terminal Directory" : "Pin Root")
            Button {
                controller.setShowHidden(!controller.presentation.showHidden)
            } label: {
                Image(systemName: controller.presentation.showHidden ? "eye" : "eye.slash")
            }
            .help("Show Hidden Files")
            Button { controller.toggleVisible() } label: { Image(systemName: "xmark") }
                .help("Hide Files Panel")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @ViewBuilder
    private var content: some View {
        if controller.needsRootSelection {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.questionmark")
                Text("Pinned Folder Unavailable").font(.headline)
                Button("Choose Root", action: controller.chooseRoot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            treeContent
        }
    }

    @ViewBuilder
    private var treeContent: some View {
        switch treeViewModel.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.folder")
                Text("Files Unavailable").font(.headline)
                Text(message).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if treeViewModel.visibleNodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text("No Files").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(treeViewModel.visibleNodes) { node in
                            FilesPanelNodeView(
                                node: node,
                                root: controller.currentRoot ?? "",
                                model: treeViewModel,
                                terminalController: terminalController,
                                readerStore: readerStore,
                                quickLook: quickLook,
                                depth: 0
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct FilesPanelNodeView: View {
    let node: FilesPanelNode
    let root: String
    @ObservedObject var model: FilesPanelTreeViewModel
    let terminalController: TerminalController?
    let readerStore: TerminalReaderStore?
    let quickLook: FilesPanelQuickLookCoordinator
    let depth: Int
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            FilesPanelRow(
                node: node,
                root: root,
                onOpen: { readerStore?.open(path: node.path) },
                onToggleDirectory: toggleDirectory,
                onQuickLook: { quickLook.toggleSpaceAction(url: URL(fileURLWithPath: node.path)) },
                onPastePath: {
                    guard let terminalController else { return }
                    FilesPanelFileActions.pasteShellEscapedPath(node.path, into: terminalController)
                },
                onOpenNewTab: {
                    guard let terminalController else { return }
                    FilesPanelFileActions.openNewVirtualTab(
                        at: node.path,
                        isDirectory: node.isDirectory,
                        from: terminalController
                    )
                }
            )
            .padding(.leading, CGFloat(depth * 14 + 8))
            .frame(height: 24)

            if isExpanded, case .loaded(let children) = node.children {
                ForEach(children) { child in
                    FilesPanelNodeView(
                        node: child,
                        root: root,
                        model: model,
                        terminalController: terminalController,
                        readerStore: readerStore,
                        quickLook: quickLook,
                        depth: depth + 1
                    )
                }
            }
        }
    }

    private func toggleDirectory() {
        isExpanded.toggle()
        if isExpanded { model.expand(path: node.path) } else { model.collapse(path: node.path) }
    }
}
