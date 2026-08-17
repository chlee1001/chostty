import AppKit
import Combine
import Foundation
import GhosttyKit

/// Owns the state of a single terminal tab/session.
///
/// `TerminalSessionState` owns only tab/session state: the stable tab UUID,
/// the split tree of surfaces, focused/remembered surface UUIDs, title/PWD/bell/progress/
/// color/config, telemetry subscriptions, a metadata generation counter, and
/// an idempotent teardown. It deliberately does **not** retain a controller or window, and
/// does not own palette, sheets, fullscreen, window frame/appearance, or the undo manager.
///
/// Those physical-owner concerns remain on the controller/window. This type is the
/// per-session value that `WorkspaceStore` and `TerminalController` compose.
final class TerminalSessionState: ObservableObject, Identifiable {
    // MARK: - Identity

    /// Stable, unique identifier for this tab/session.
    let id: UUID

    // MARK: - Session-owned published state

    /// The live split tree of surfaces belonging to this session.
    ///
    /// Structural topology is **not** published on the session.
    /// The owning ``WorkspaceSessionStore`` is the sole structural publisher; this
    /// stored property is mutated only by store commit (via the owning controller)
    /// so that observation of structural change happens through exactly one
    /// `@Published` snapshot on the store.
    var surfaceTree: SplitTree<Ghostty.SurfaceView>

    /// The UUID of the surface that currently has focus within this session.
    ///
    /// Not `@Published`: structural/topological state. Updated only by store commit.
    var focusedSurfaceID: UUID?

    /// The surface that was last focused; used as a fallback when reactivating.
    ///
    /// Not `@Published`: structural/topological state. Updated only by store commit.
    var rememberedSurfaceID: UUID?

    /// The computed terminal title (without any user override).
    @Published var title: String

    /// The working directory reported by the PTY, if any.
    @Published var pwd: String?

    /// `true` when any surface in this session has an active bell.
    @Published var bell: Bool

    /// Optional progress value (0–100) reported by the terminal.
    @Published var progress: UInt8?

    /// Optional tab color string that projects to physical chrome.
    @Published var tabColor: String?

    /// A user-supplied title override; takes precedence over `title`.
    @Published var titleOverride: String?

    let readerStore = TerminalReaderStore()

    // MARK: - Telemetry / lifecycle

    /// Monotonically increasing generation counter. Bumped whenever session metadata
    /// (title, PWD, bell, progress, color, config) changes so that observers can
    /// coalesce/deduplicate work.
    private(set) var metadataGeneration: UInt64 = 0

    /// Combine subscriptions tied to telemetry for surfaces in this session.
    /// Cleared on teardown.
    private var telemetryCancellables: Set<AnyCancellable> = []

    /// `true` after `tearDown()` has been called at least once.
    private(set) var isTornDown = false

    // MARK: - Initializers

    /// Adopts an existing split tree without creating any surface.
    ///
    /// Sessions never create their own default surface. The
    /// caller (graph factory, restoration, transfer, or owning controller) must
    /// inject a fully constructed tree; this is the sole non-test initializer.
    ///
    /// - Parameters:
    ///   - id: Stable tab UUID.
    ///   - surfaceTree: An existing tree to adopt. May be empty.
    init(id: UUID, surfaceTree: SplitTree<Ghostty.SurfaceView>) {
        self.id = id
        self.surfaceTree = surfaceTree
        self.focusedSurfaceID = nil
        self.rememberedSurfaceID = nil
        self.title = "👻"
        self.pwd = nil
        self.bell = false
        self.progress = nil
        self.tabColor = nil
        self.titleOverride = nil
    }


    // MARK: - Teardown

    // MARK: - Presentation lifecycle

    /// Detaches this session from active presentation without destroying state.
    ///
    /// This is the inverse of mounting: called by the owning
    /// controller when this session is no longer the presented one (e.g. when
    /// the user switches to a different tab). Unlike ``tearDown()``, this does
    /// NOT release surfaces, PTYs, telemetry subscriptions, or focus state —
    /// those are retained so the session can be re-mounted later.
    ///
    /// This hook establishes a presentation-lifecycle boundary distinct from
    /// final teardown. The implementation is intentionally non-destructive;
    /// future phases may use this hook to release presentation-only resources
    /// without ending the underlying PTY.
    func unmount() {
        // Presentation lifecycle boundary. State is preserved for re-mounting.
    }

    /// Idempotently tears down the session.
    ///
    /// After the first call:
    /// - `isTornDown` is set to `true`.
    /// - All telemetry subscriptions are cancelled.
    /// - The surface tree is replaced with an empty tree, releasing references to
    ///   any surfaces this session owned.
    ///
    /// Subsequent calls are a no-op. This does **not** destroy underlying PTYs or
    /// surfaces — the owning controller or detached lease is responsible for that.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        readerStore.closeAll()
        telemetryCancellables.removeAll()
        surfaceTree = .init()
        focusedSurfaceID = nil
        rememberedSurfaceID = nil
    }

    // MARK: - Metadata

    /// Increments the metadata generation counter, signalling observers that session
    /// metadata has changed.
    func bumpMetadataGeneration() {
        metadataGeneration &+= 1
    }

}
