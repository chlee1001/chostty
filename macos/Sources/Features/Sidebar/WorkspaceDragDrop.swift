import SwiftUI
import AppKit
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

// MARK: - Tab tear-off notification

extension Notification.Name {
    /// Posted when a virtual-tab drag ends with no drop target claiming it and
    /// the release point lies outside the tab strip — the tear-off gesture.
    /// The object is nil (a broadcast); `userInfo` carries the dragged tab's
    /// UUID under `ghosttyTabDragEndedNoTargetTabIDKey` and the release point
    /// under `ghosttyTabDragEndedNoTargetPointKey`. Only the controller whose
    /// store still owns the tab acts on it.
    static let ghosttyTabDragEndedNoTarget = Notification.Name("ghosttyTabDragEndedNoTarget")

    /// userInfo key for the dragged tab's UUID.
    static let ghosttyTabDragEndedNoTargetTabIDKey = "tabID"

    /// userInfo key for the screen-space release point (`NSPoint`).
    static let ghosttyTabDragEndedNoTargetPointKey = "point"
}

// MARK: - Tab tear-off drag source
//
// The strip's tab items start their drags from an AppKit `NSDraggingSource`
// instead of SwiftUI `.draggable(String)`. A String Transferable drag that
// leaves the app is offered to Finder as copyable text, which writes
// `chostty.tab-*.textClipping` files; the AppKit source instead returns an
// empty operation mask outside the app, so the drag simply ends with
// `operation == []` and posts the existing `.ghosttyTabDragEndedNoTarget`
// broadcast when the release point is outside the strip.
//
// The strip's SwiftUI `.dropDestination(for: String.self)` targets stay
// exactly as they are, so in-strip reorder visuals and behavior are
// unchanged, and `workspaceReorderable` (used by the sidebar) is untouched.

/// Geometry shared by the strip anchor and every tab drag source.
@MainActor
final class VirtualTabDragContext {
    private weak var anchorView: NSView?

    func attach(_ view: NSView) {
        anchorView = view
    }

    /// Screen-space frame of the strip, if its anchor is in a window.
    var stripFrame: NSRect? {
        guard let anchor = anchorView, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    func contains(_ screenPoint: NSPoint) -> Bool {
        guard let stripFrame else { return false }
        return stripFrame.insetBy(dx: -4, dy: -4).contains(screenPoint)
    }
}

/// Transparent geometry anchor for the strip. Never intercepts clicks or
/// drags; exists only to give the drag context the strip's frame.
struct VirtualTabDragStripAnchor: NSViewRepresentable {
    let context: VirtualTabDragContext

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        self.context.attach(nsView)
    }

    final class AnchorView: NSView {
        override func hitTest(_ p: NSPoint) -> NSView? { nil }
    }
}

/// Starts tab-item drags from AppKit so their lifecycle (and, critically,
/// their end operation) is observable. The view itself is transparent and
/// hit-test-nil: SwiftUI keeps every click, double-click, rename, close,
/// hover, context-menu, and drop-destination behavior. The drag session is
/// initiated from a local `.leftMouseDragged` monitor, which observes events
/// without consuming them.
struct VirtualTabDragSource: NSViewRepresentable {
    let context: VirtualTabDragContext
    let payload: WorkspaceDragPayload
    let previewText: String

    /// While true the item is editing (inline rename) and must not start a
    /// drag: a drag-to-select inside the rename field would otherwise start a
    /// tab drag — even a tear-off — mid-edit.
    var dragDisabled: Bool = false

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.configure(context: self.context, payload: payload, previewText: previewText, dragDisabled: dragDisabled)
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.configure(context: self.context, payload: payload, previewText: previewText, dragDisabled: dragDisabled)
    }

    /// Main-actor isolated, so `configure`/`deinit` always run on the main
    /// thread: monitor install/removal never races. One lightweight observer
    /// per tab item is cheaper than routing every strip drag through a single
    /// shared monitor with per-item hit-testing.
    @MainActor
    final class DragSourceView: NSView, NSDraggingSource {
        /// Minimum accumulated pointer travel before a press becomes a drag,
        /// so click jitter never converts a tap-select into a drag session.
        static let dragThreshold: CGFloat = 3

        private weak var dragContext: VirtualTabDragContext?
        private var payload: WorkspaceDragPayload?
        private var previewText: String = ""
        private var dragDisabled = false
        private var dragMonitor: Any?
        private var pressMonitor: Any?
        private var escapeMonitor: Any?
        private var escapeCancelled = false
        private var sessionActive = false
        private var pressPoint: NSPoint?

        func configure(context: VirtualTabDragContext, payload: WorkspaceDragPayload, previewText: String, dragDisabled: Bool) {
            self.dragContext = context
            self.payload = payload
            self.previewText = previewText
            self.dragDisabled = dragDisabled
            if dragMonitor == nil {
                dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                    self?.handleMouseDragged(event)
                    return event
                }
            }
            if pressMonitor == nil {
                pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    self?.handleMouseDown(event)
                    return event
                }
            }
        }

        override func hitTest(_ p: NSPoint) -> NSView? { nil }

        private func handleMouseDown(_ event: NSEvent) {
            guard let window = window,
                  event.windowNumber == window.windowNumber,
                  NSPointInRect(convert(event.locationInWindow, from: nil), bounds) else { return }
            pressPoint = event.locationInWindow
        }

        /// Pure, unit-testable: has the pointer travelled far enough from the
        /// press point for this dragged event to start a session?
        static func crossedThreshold(from pressPoint: NSPoint?, to event: NSEvent) -> Bool {
            guard let pressPoint else { return true }
            let dx = event.locationInWindow.x - pressPoint.x
            let dy = event.locationInWindow.y - pressPoint.y
            return (dx * dx + dy * dy).squareRoot() >= dragThreshold
        }

        private func handleMouseDragged(_ event: NSEvent) {
            guard !sessionActive,
                  !dragDisabled,
                  let window = window,
                  event.windowNumber == window.windowNumber,
                  NSPointInRect(convert(event.locationInWindow, from: nil), bounds),
                  Self.crossedThreshold(from: pressPoint, to: event),
                  let payload else { return }
            pressPoint = nil
            beginSession(for: payload, event: event)
        }

        private func beginSession(for payload: WorkspaceDragPayload, event: NSEvent) {
            let item = NSPasteboardItem()
            // Plain-text only, written directly: no Transferable/UTI vendor
            // surface for Finder to copy out as a `.textClipping` file.
            item.setString(payload.stringValue, forType: .string)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(
                NSRect(origin: .zero, size: NSSize(width: 120, height: 24)),
                contents: VirtualTabDragSource.dragPreview(text: previewText))

            sessionActive = true
            escapeCancelled = false
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.escapeCancelled = true }
                return event
            }
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        // MARK: NSDraggingSource

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            Self.sourceOperationMask(for: context)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint
        ) {
            // No-op: Escape/cancel state is already armed in `beginSession`.
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            defer {
                sessionActive = false
                if let escapeMonitor {
                    NSEvent.removeMonitor(escapeMonitor)
                    self.escapeMonitor = nil
                }
            }
            guard Self.shouldPostTearOff(
                operation: operation,
                escapeCancelled: escapeCancelled,
                releaseInsideStrip: dragContext?.contains(screenPoint) ?? true
            ),
                  let payload,
                  case .tab(let tabID) = payload else { return }
            NotificationCenter.default.post(
                name: .ghosttyTabDragEndedNoTarget,
                object: nil,
                userInfo: [
                    Notification.Name.ghosttyTabDragEndedNoTargetTabIDKey: tabID,
                    Notification.Name.ghosttyTabDragEndedNoTargetPointKey: screenPoint
                ])
        }

        /// Pure, unit-testable: the operation mask offered per context.
        /// Outside the app the mask is empty, which is exactly what stops
        /// Finder from accepting the drag as copyable text (no `.textClipping`).
        static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        /// Pure, unit-testable: when an ended session becomes a tear-off.
        /// A claimed in-app drop reports `.move`; only an unclaimed,
        /// non-cancelled release outside the strip tears off.
        static func shouldPostTearOff(
            operation: NSDragOperation,
            escapeCancelled: Bool,
            releaseInsideStrip: Bool
        ) -> Bool {
            operation == [] && !escapeCancelled && !releaseInsideStrip
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A representable can recycle this view across items; a stale
            // session must never pin the old payload to a new item.
            if window == nil { sessionActive = false }
        }

        deinit {
            if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
            if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        }
    }

    /// Stable drag preview: a small labeled chip. Deliberately independent of
    /// the live SwiftUI hierarchy so a re-render mid-drag cannot change it.
    static func dragPreview(text: String) -> NSImage {
        let size = NSSize(width: 120, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
        let title = (text.isEmpty ? "Terminal" : text) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2),
            withAttributes: attributes)
        image.unlockFocus()
        return image
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
