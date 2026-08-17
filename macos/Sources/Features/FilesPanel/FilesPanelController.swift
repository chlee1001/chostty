import AppKit
import Combine
import Foundation

@MainActor
final class FilesPanelController: ObservableObject {
    @Published var presentation: FilesPanelPresentationState {
        didSet {
            persistDefaults()
            guard oldValue.rootMode != presentation.rootMode ||
                    oldValue.pinnedRoot != presentation.pinnedRoot ||
                    oldValue.showHidden != presentation.showHidden else { return }
            refreshRoot()
        }
    }
    /// Persisted-only stream: current root, reader state, and auto-collapse never appear here.
    var persistedProjection: AnyPublisher<FilesPanelPresentationState.Persisted, Never> {
        $presentation
            .map(\.persisted)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    let treeViewModel: FilesPanelTreeViewModel
    let readerBudget: FilesPanelReaderMemoryBudget

    private let watchBroker: FilesPanelWatchBroker
    private let rootResolver = FilesPanelRootResolver()
    private weak var controller: TerminalController?
    private var watchSubscription: FilesPanelWatchBroker.Subscription?
    private var sessionRosterCancellable: AnyCancellable?
    @Published private(set) var currentRoot: String?
    @Published private(set) var needsRootSelection = false
    private var rootRefreshTask: Task<Void, Never>?

    init(
        seed: FilesPanelPresentationState.Seed = .fromDefaults(),
        watchBroker: FilesPanelWatchBroker,
        treeViewModel: FilesPanelTreeViewModel? = nil,
        readerBudget: FilesPanelReaderMemoryBudget = .init()
    ) {
        presentation = .init(seed: seed)
        self.watchBroker = watchBroker
        self.treeViewModel = treeViewModel ?? .init()
        self.readerBudget = readerBudget
    }

    func attach(to controller: TerminalController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        attachReaderBudgets(controller.workspaceStore.allSessions)
        sessionRosterCancellable = controller.workspaceStore.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.attachReaderBudgets(controller.workspaceStore.allSessions)
                if self.presentation.rootMode == .followPWD { self.refreshRoot() }
            }
        refreshRoot()
    }

    func hydrate(from persisted: FilesPanelPresentationState.Persisted) {
        presentation.visible = persisted.visible
        presentation.width = persisted.width
        presentation.rootMode = persisted.rootMode
        presentation.pinnedRoot = persisted.pinnedRoot
        presentation.showHidden = persisted.showHidden
    }

    func toggleVisible() {
        presentation.visible.toggle()
        if presentation.visible { refreshRoot() }
    }

    func pin(root: String) {
        presentation.rootMode = .pinned
        presentation.pinnedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
    }

    func followPWD() {
        presentation.rootMode = .followPWD
        presentation.pinnedRoot = nil
    }

    func setShowHidden(_ value: Bool) {
        presentation.showHidden = value
    }

    func refreshRoot() {
        guard presentation.visible, let controller else { return }
        let root: String
        switch presentation.rootMode {
        case .pinned:
            guard let pinnedRoot = presentation.pinnedRoot else {
                needsRootSelection = true
                return
            }
            root = pinnedRoot
        case .followPWD:
            let session = controller.presentedSessionID.flatMap(controller.workspaceStore.session(forTabID:))
            root = rootResolver.resolve(.init(
                focusedPanePWD: controller.focusedSurface?.pwd,
                sessionPWD: session?.pwd,
                workspacePWD: controller.workspaceStore.selectedWorkspace?.defaultDirectory
            ))
        }

        rootRefreshTask?.cancel()
        rootRefreshTask = Task { [weak self] in
            guard let self else { return }
            if self.presentation.rootMode == .pinned {
                let isDirectory = await Self.isDirectory(path: root)
                guard !Task.isCancelled else { return }
                guard self.presentation.rootMode == .pinned,
                      self.presentation.pinnedRoot == root else { return }
                self.needsRootSelection = !isDirectory
                guard isDirectory else {
                    self.watchSubscription?.cancel()
                    self.watchSubscription = nil
                    self.currentRoot = nil
                    return
                }
            } else {
                self.needsRootSelection = false
            }
            self.activateRoot(root)
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pin(root: url.path)
    }

    nonisolated static func isDirectory(path: String) async -> Bool {
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) &&
                isDirectory.boolValue
        }.value
    }

    private func activateRoot(_ root: String) {
        if currentRoot != root {
            currentRoot = root
            watchSubscription?.cancel()
            // A recursive file-event stream on `/` or the home directory is an
            // event storm, not a refresh. Those roots list on demand instead.
            watchSubscription = FilesPanelWatchBroker.isBroadRoot(root)
                ? nil
                : watchBroker.subscribe(root: root) { [weak self] changedPaths in
                    Task { @MainActor in
                        guard let self else { return }
                        self.treeViewModel.reload()
                        self.controller?.workspaceStore.allSessions.forEach {
                            $0.readerStore.markStale(paths: changedPaths)
                        }
                    }
                }
        }
        treeViewModel.load(root: root, showHidden: presentation.showHidden)
    }

    func teardown() {
        rootRefreshTask?.cancel()
        rootRefreshTask = nil
        watchSubscription?.cancel()
        watchSubscription = nil
        sessionRosterCancellable?.cancel()
        sessionRosterCancellable = nil
        controller = nil
    }

    private func attachReaderBudgets(_ sessions: [TerminalSessionState]) {
        sessions.forEach { $0.readerStore.attach(budget: readerBudget) }
    }

    private func persistDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(presentation.visible, forKey: "chostty.filesPanelVisible")
        defaults.set(presentation.width, forKey: "chostty.filesPanelWidth")
        defaults.set(presentation.showHidden, forKey: "chostty.filesPanelShowHidden")
    }
}
