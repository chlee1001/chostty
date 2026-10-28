import SwiftUI
import GhosttyKit

func sortedTerminalPaletteOptions(_ options: [CommandOption]) -> [CommandOption] {
    options.sorted { lhs, rhs in
        let lhsTitle = lhs.title.replacingOccurrences(of: ":", with: "\t")
        let rhsTitle = rhs.title.replacingOccurrences(of: ":", with: "\t")
        let comparison = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        if let lhsKey = lhs.sortKey, let rhsKey = rhs.sortKey {
            return lhsKey < rhsKey
        }
        return false
    }
}

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: commandOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            if newValue,
               let controller = surfaceView.window?.windowController as? BaseTerminalController {
                controller.sshCapability?.services.catalog.refreshIfStale()
            }

            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// All commands available in the command palette, combining update and terminal options.
    private var commandOptions: [CommandOption] {
        Self.mergeCommandOptions(
            updates: updateOptions,
            others: jumpOptions + terminalOptions + workspaceOptions,
            ssh: sshOptions)
    }

    static func mergeCommandOptions(
        updates: [CommandOption],
        others: [CommandOption],
        ssh sshOptions: [CommandOption]
    ) -> [CommandOption] {
        var options: [CommandOption] = []
        // Updates always appear first
        options.append(contentsOf: updates)

        // Sort the rest. We replace ":" with a character that sorts before space
        // so that "Foo:" sorts before "Foo Bar:". Use sortKey as a tie-breaker
        // for stable ordering when titles are equal.
        func normalized(_ title: String) -> String { title.replacingOccurrences(of: ":", with: "\t") }
        var sorted = others.sorted { a, b in
            let comparison = normalized(a.title).localizedCaseInsensitiveCompare(normalized(b.title))
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // Tie-breaker: use sortKey if both have one
            if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
                return aSortKey < bSortKey
            }
            return false
        }
        // SSH entries keep their own order (favorites first) as one block,
        // placed where "SSH:" falls alphabetically.
        let sshPosition = sorted.firstIndex {
            normalized($0.title).localizedCaseInsensitiveCompare(normalized("SSH:")) == .orderedDescending
        } ?? sorted.endIndex
        sorted.insert(contentsOf: sshOptions, at: sshPosition)
        options.append(contentsOf: sorted)
        return options
    }

    /// Commands for installing or canceling available updates.
    private var updateOptions: [CommandOption] {
        var options: [CommandOption] = []

        guard let updateViewModel else {
            return options
        }

        if updateViewModel.state.isInstallable {
            // We override the update available one only because we want to properly
            // convey it'll go all the way through.
            let title: String
            if case .updateAvailable = updateViewModel.state {
                title = "Update Chostty and Restart"
            } else {
                title = updateViewModel.text
            }

            options.append(CommandOption(
                title: title,
                description: updateViewModel.description,
                leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
                badge: updateViewModel.badge,
                emphasis: true
            ) {
                (NSApp.delegate as? AppDelegate)?.updateController.viewModel.state.confirm()
            })
        }

        if updateViewModel.state.isCancellable {
            options.append(CommandOption(
                title: "Cancel or Skip Update",
                description: "Dismiss the current update process"
            ) {
                updateViewModel.state.cancel()
            })
        }

        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                let symbols = appDelegate.ghostty.config.keyboardShortcut(for: c.action)?.keyList
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: symbols
                ) {
                    onAction(c.action)
                }
            }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            // Non-presented tabs' surfaces live on their session's own tree,
            // not `controller.surfaceTree` (the controller's live/presented
            // tree only). `allWorkspaceSurfaces` already makes this split so
            // Focus entries reach every tab, presented or not.
            return controller.allWorkspaceSurfaces.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = "Untitled"
                }
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: ObjectIdentifier(surface)
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

    /// Commands for switching workspaces and workspace-scoped actions (new
    /// workspace, rename, duplicate tab, reopen closed tab). The enumeration
    /// itself lives in ``workspaceCommandOptions(store:perform:)`` so it is
    /// unit-testable headlessly, without a live window.
    private var workspaceOptions: [CommandOption] {
        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else {
            return []
        }
        return Self.workspaceCommandOptions(store: controller.workspaceStore) { action in
            Self.perform(action, on: controller)
        }
    }

    private var sshOptions: [CommandOption] {
        guard let controller = surfaceView.window?.windowController as? BaseTerminalController else { return [] }
        let capability = controller.sshCapability
        let tunnels: [SSHTunnelCommand] = capability.map { capability in
            let controller = capability.services.tunnels
            return controller.definitions.compactMap { definition -> SSHTunnelCommand? in
                if controller.isRunning(definition.id) { return SSHTunnelCommand(definition: definition, isRunning: true) }
                guard controller.startBlocker(for: definition) == nil else { return nil }
                return SSHTunnelCommand(definition: definition, isRunning: false)
            }
        } ?? []
        return Self.sshCommandOptions(
            isAvailable: capability != nil,
            hosts: capability?.services.catalog.snapshot.entries ?? [],
            tunnels: tunnels
        ) { action in
            switch action {
            case let .connect(reference): capability?.connect(reference, inSplit: false)
            case let .connectInSplit(reference): capability?.connect(reference, inSplit: true)
            case .manageHosts: capability?.showHosts()
            case let .startTunnel(id): capability?.startTunnel(id)
            case let .stopTunnel(id): capability?.stopTunnel(id)
            }
        }
    }

    enum SSHCommandAction {
        case connect(SSHHostReference)
        case connectInSplit(SSHHostReference)
        case manageHosts
        case startTunnel(UUID)
        case stopTunnel(UUID)
    }

    /// A tunnel the palette can act on: running ones offer Stop, startable ones Start.
    struct SSHTunnelCommand {
        let definition: SSHTunnelDefinition
        let isRunning: Bool
    }

    static func sshCommandOptions(
        isAvailable: Bool,
        hosts: [SSHHostEntry],
        tunnels: [SSHTunnelCommand] = [],
        perform: @escaping (SSHCommandAction) -> Void
    ) -> [CommandOption] {
        guard isAvailable else { return [] }
        // Hosts arrive in catalog order, which already puts favorites first.
        return hosts.flatMap { host in
            [
                CommandOption(title: "SSH: Connect to \(host.reference.alias)", leadingIcon: "terminal") {
                    perform(.connect(host.reference))
                },
                CommandOption(title: "SSH: Connect to \(host.reference.alias) in Split", leadingIcon: "rectangle.split.2x1") {
                    perform(.connectInSplit(host.reference))
                },
            ]
        } + tunnels.map { tunnel in
            let id = tunnel.definition.id
            return tunnel.isRunning
                ? CommandOption(title: "SSH: Stop Tunnel \(tunnel.definition.name)", leadingIcon: "stop.circle") {
                    perform(.stopTunnel(id))
                }
                : CommandOption(title: "SSH: Start Tunnel \(tunnel.definition.name)", leadingIcon: "point.3.connected.trianglepath.dotted") {
                    perform(.startTunnel(id))
                }
        } + [CommandOption(title: "SSH: Manage Hosts…", leadingIcon: "server.rack") {
            perform(.manageHosts)
        }]
    }

    /// Real command paths a workspace command-palette entry can invoke.
    enum WorkspaceCommandAction {
        case switchTo(workspaceID: UUID, tabID: UUID)
        case newWorkspace
        case renameWorkspace(UUID)
        case duplicateTab(UUID)
        case reopenClosedTab
    }

    /// Builds one switch entry per workspace in `store`, in snapshot
    /// (workspace-then-tab) order, plus New Workspace / Rename Workspace /
    /// Duplicate Tab / Reopen Closed Tab. Store-driven (rather than reading
    /// `TerminalController.all`) so it is testable through
    /// `TerminalControllerTestHarness` without a real window.
    static func workspaceCommandOptions(
        store: WorkspaceSessionStore,
        perform: @escaping (WorkspaceCommandAction) -> Void
    ) -> [CommandOption] {
        var options: [CommandOption] = []

        for (index, workspace) in store.snapshot.workspaces.enumerated() {
            guard let tabID = workspace.selectedTabID ?? workspace.tabs.first?.id else { continue }
            let tabCount = workspace.tabs.count
            let selectedTitle = workspace.selectedTab.map { $0.titleOverride ?? $0.title } ?? ""
            var subtitle = "\(tabCount) tab\(tabCount == 1 ? "" : "s")"
            if !selectedTitle.isEmpty {
                subtitle += " · \(selectedTitle)"
            }

            options.append(CommandOption(
                title: "Switch to: \(workspace.name)",
                subtitle: subtitle,
                leadingIcon: "square.grid.2x2",
                leadingColor: workspace.color.displayColor.map { Color($0) },
                sortKey: AnySortKey(index)
            ) {
                perform(.switchTo(workspaceID: workspace.id, tabID: tabID))
            })
        }

        options.append(CommandOption(
            title: "New Workspace",
            leadingIcon: "plus.square.on.square"
        ) {
            perform(.newWorkspace)
        })

        if let selectedWorkspace = store.selectedWorkspace {
            options.append(CommandOption(
                title: "Rename Workspace",
                leadingIcon: "pencil"
            ) {
                perform(.renameWorkspace(selectedWorkspace.id))
            })
        }

        let selectedTabID = store.snapshot.selection.tabID
        options.append(CommandOption(
            title: "Duplicate Tab",
            leadingIcon: "plus.rectangle.on.rectangle"
        ) {
            perform(.duplicateTab(selectedTabID))
        })

        options.append(CommandOption(
            title: "Reopen Closed Tab",
            leadingIcon: "arrow.uturn.backward"
        ) {
            perform(.reopenClosedTab)
        })

        return options
    }

    /// Executes a workspace command-palette action through the SAME
    /// production entry points every other surface (menu, reserved
    /// shortcuts, AppleScript) uses — never a bespoke path.
    static func perform(_ action: WorkspaceCommandAction, on controller: BaseTerminalController) {
        switch action {
        case .switchTo(let workspaceID, let tabID):
            controller.selectSession(workspaceID: workspaceID, tabID: tabID)
        case .newWorkspace:
            _ = (NSApp.delegate as? AppDelegate)?.terminalCommands.perform(
                .newWorkspace, source: controller.focusedSurface)
        case .renameWorkspace(let workspaceID):
            controller.workspaceStore.promptRenameWorkspace(workspaceID)
        case .duplicateTab(let tabID):
            controller.duplicateTab(tabID)
        case .reopenClosedTab:
            controller.reopenClosedTab()
        }
    }

}

/// This is done to ensure that the given view is in the responder chain.
private struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
