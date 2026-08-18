import Foundation

/// Pane trees for tabs that were restored from disk but not yet turned into
/// live surfaces.
///
/// Boot materializes only the selected tab of the selected workspace; the rest
/// wait here until first selected. The save path must be able to read this map:
/// a pending tab's live tree is empty by construction, so projecting it from
/// the live graph would write "this tab has no panes" and, one timer tick
/// later, erase the structure of every tab the user had not opened.
///
/// Owned by the application rather than a window controller. Closing a window
/// and undoing it rebuilds a new controller around the same live sessions, and
/// a controller-owned map would die with the old one. Keying by tab UUID also
/// survives `store.moveTab`, which only reorders within a store.
@MainActor
final class PendingHydrationRegistry {
    private var entries: [UUID: TabSnapshot] = [:]

    init() {}

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func store(_ snapshot: TabSnapshot, for tabID: UUID) {
        entries[tabID] = snapshot
    }

    func snapshot(for tabID: UUID) -> TabSnapshot? {
        entries[tabID]
    }

    func contains(_ tabID: UUID) -> Bool {
        entries[tabID] != nil
    }

    @discardableResult
    func take(_ tabID: UUID) -> TabSnapshot? {
        entries.removeValue(forKey: tabID)
    }

    /// Reopening a closed tab can mint a fresh session, so the pending
    /// structure has to follow it rather than being stranded under the old key.
    func rekey(from oldID: UUID, to newID: UUID) {
        guard let entry = entries.removeValue(forKey: oldID) else { return }
        entries[newID] = TabSnapshot(
            id: newID,
            titleOverride: entry.titleOverride,
            tabColor: entry.tabColor,
            paneTree: entry.paneTree,
            focusedPaneID: entry.focusedPaneID,
            zoomedPaneID: entry.zoomedPaneID
        )
    }

    /// For the save path.
    var allPending: [UUID: TabSnapshot] { entries }
}
