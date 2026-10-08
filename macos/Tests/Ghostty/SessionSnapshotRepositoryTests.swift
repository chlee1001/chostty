import Foundation
import Testing
@testable import Ghostty

/// Atomic write, identical-bytes skip, schema rejection, backup promotion and
/// fallback, and the load validator. Every test injects a temporary directory,
/// so nothing here touches the real `~/Library/Application Support`.
@Suite struct SessionSnapshotRepositoryTests {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLeaf(cwd: String? = "/tmp") -> PaneLeafSnapshot {
        PaneLeafSnapshot(uuid: UUID(), cwd: cwd, title: nil)
    }

    private func makeTab(id: UUID = UUID(), panes: Int = 1) -> TabSnapshot {
        var tree: PaneTreeSnapshot = .leaf(makeLeaf())
        for _ in 1..<max(panes, 1) {
            tree = .split(direction: .horizontal, ratio: 0.5, left: tree, right: .leaf(makeLeaf()))
        }
        return TabSnapshot(
            id: id,
            titleOverride: nil,
            tabColor: nil,
            paneTree: tree,
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
    }

    private func makeWorkspace(tabs: [TabSnapshot], selectedTabID: UUID? = nil) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: UUID(),
            name: "Workspace 1",
            color: .none,
            isCollapsed: false,
            defaultDirectory: nil,
            tabs: tabs,
            selectedTabID: selectedTabID ?? tabs.first?.id
        )
    }

    private func makeSnapshot(
        ownerInstanceID: UUID = UUID(),
        ownerPID: Int32 = 1234,
        workspaces: [WorkspaceSnapshot]? = nil
    ) -> AppSessionSnapshot {
        let resolved = workspaces ?? [makeWorkspace(tabs: [makeTab()])]
        let window = WindowSnapshot(
            physicalUUID: UUID(),
            selection: resolved.first.flatMap { ws in
                ws.selectedTabID.map { SelectionSnapshot(workspaceID: ws.id, tabID: $0) }
            },
            workspaces: resolved
        )
        return AppSessionSnapshot(ownerInstanceID: ownerInstanceID, ownerPID: ownerPID, windows: [window])
    }

    private func modificationDate(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    // MARK: - Default location

    @Test func defaultDirectoryDerivesFromBundleIdentifier() {
        let debug = SessionSnapshotRepository.defaultDirectory(bundleIdentifier: "com.chostty.app.debug")
        let release = SessionSnapshotRepository.defaultDirectory(bundleIdentifier: "com.chostty.app")

        // A Debug build must not write into the release app's directory.
        #expect(debug.lastPathComponent == "com.chostty.app.debug")
        #expect(release.lastPathComponent == "com.chostty.app")
        #expect(debug != release)
    }

    // MARK: - Saving

    @Test func firstSaveWritesPrimaryWithOwnerOnlyPermissions() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)

        #expect(try repository.save(makeSnapshot()) == .written)
        #expect(FileManager.default.fileExists(atPath: repository.primaryURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: repository.primaryURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)
    }

    @Test func identicalSnapshotLeavesBothSlotsUntouched() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let snapshot = makeSnapshot()

        #expect(try repository.save(makeSnapshot()) == .written)
        #expect(try repository.save(snapshot) == .written)
        let primary = try Data(contentsOf: repository.primaryURL)
        let backup = try Data(contentsOf: repository.backupURL)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        for url in [repository.primaryURL, repository.backupURL] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        let primaryDate = try modificationDate(repository.primaryURL)
        let backupDate = try modificationDate(repository.backupURL)

        #expect(try repository.save(snapshot) == .skippedIdentical)
        #expect(try repository.save(snapshot) == .skippedIdentical)
        #expect(try Data(contentsOf: repository.primaryURL) == primary)
        #expect(try Data(contentsOf: repository.backupURL) == backup)
        #expect(try modificationDate(repository.primaryURL) == primaryDate)
        #expect(try modificationDate(repository.backupURL) == backupDate)
    }

    @Test func changedSnapshotIsWritten() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let ownerID = UUID()

        #expect(try repository.save(makeSnapshot(ownerInstanceID: ownerID, ownerPID: 1)) == .written)
        #expect(try repository.save(makeSnapshot(ownerInstanceID: ownerID, ownerPID: 2)) == .written)

        guard case .loaded(let loaded, _) = repository.load() else {
            Issue.record("expected a usable snapshot")
            return
        }
        #expect(loaded.ownerPID == 2)
    }

    @Test func overLimitSnapshotIsRefusedAndPreviousFileSurvives() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let good = makeSnapshot()
        #expect(try repository.save(good) == .written)

        let windows = (0..<(SessionSnapshotValidator.Limits.windows + 1)).map { _ in
            WindowSnapshot(physicalUUID: UUID(), selection: nil, workspaces: [makeWorkspace(tabs: [makeTab()])])
        }
        let tooMany = AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 9, windows: windows)

        let outcome = try repository.save(tooMany)
        #expect(outcome == .refusedInvalid(.limitExceeded(
            kind: "window",
            count: SessionSnapshotValidator.Limits.windows + 1,
            limit: SessionSnapshotValidator.Limits.windows
        )))

        // The previously valid file is still on disk.
        guard case .loaded(let loaded, let source) = repository.load() else {
            Issue.record("expected the previous file to survive")
            return
        }
        #expect(source == .primary)
        #expect(loaded.windows.count == 1)
    }

    // MARK: - Loading and fallback

    @Test func emptySavePreservesValidPrimaryBytes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let good = makeSnapshot()
        #expect(try repository.save(good) == .written)
        let original = try Data(contentsOf: repository.primaryURL)

        let empty = AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 1, windows: [])
        #expect(try repository.save(empty) == .refusedInvalid(.noWindows))
        #expect(try Data(contentsOf: repository.primaryURL) == original)
        #expect(repository.load() == .loaded(good, source: .primary))
    }

    @Test func successfulSavesLoadTheirValidatedValue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let ordinary = makeSnapshot()
        let danglingSelection = makeSnapshot(workspaces: [
            makeWorkspace(tabs: [makeTab(panes: 3)], selectedTabID: UUID())
        ])
        let emptyTree = TabSnapshot(
            id: UUID(), titleOverride: "", tabColor: nil, paneTree: nil,
            focusedPaneID: UUID(), zoomedPaneID: UUID()
        )
        let emptyTreeSnapshot = makeSnapshot(workspaces: [makeWorkspace(tabs: [emptyTree])])

        for snapshot in [ordinary, danglingSelection, emptyTreeSnapshot] {
            guard case .success(let validated) = SessionSnapshotValidator.validate(snapshot) else {
                Issue.record("fixture must be valid after selection repair")
                return
            }
            #expect(try repository.save(snapshot) == .written)
            #expect(repository.load() == .loaded(validated, source: .primary))
            #expect(try repository.save(snapshot) == .skippedIdentical)
            #expect(repository.load() == .loaded(validated, source: .primary))
        }
    }

    @Test func encodedResourceLimitRefusesOtherwiseValidSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let good = makeSnapshot()
        #expect(try repository.save(good) == .written)
        let original = try Data(contentsOf: repository.primaryURL)
        let text = String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength)
        let workspaces = (0..<SessionSnapshotValidator.Limits.workspacesPerWindow).map { _ in
            makeWorkspace(tabs: (0..<4).map { _ in
                TabSnapshot(
                    id: UUID(), titleOverride: text, tabColor: nil,
                    paneTree: .leaf(makeLeaf(cwd: text)),
                    focusedPaneID: nil, zoomedPaneID: nil
                )
            })
        }
        let snapshot = makeSnapshot(workspaces: workspaces)
        guard case .success(let validated) = SessionSnapshotValidator.validate(snapshot) else {
            Issue.record("fixture must pass value validation")
            return
        }
        let byteCount = try SessionSnapshotRepository.encoder.encode(validated).count
        #expect(byteCount > SessionSnapshotRepository.maxFileBytes)
        #expect(try repository.save(snapshot) == .refusedInvalid(.limitExceeded(
            kind: "fileBytes", count: byteCount, limit: SessionSnapshotRepository.maxFileBytes
        )))
        #expect(try Data(contentsOf: repository.primaryURL) == original)
        #expect(repository.load() == .loaded(good, source: .primary))
    }

    @Test func absentFilesLoadAsAbsent() throws {
        let repository = SessionSnapshotRepository(directory: try makeTemporaryDirectory())
        #expect(repository.load() == .absent)
    }

    @Test func versionMismatchIsUnusable() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let future = AppSessionSnapshot(
            version: AppSessionSnapshot.currentVersion + 1,
            ownerInstanceID: UUID(),
            ownerPID: 1,
            windows: makeSnapshot().windows
        )
        try SessionSnapshotRepository.encoder.encode(future).write(to: repository.primaryURL)

        guard case .unusable(let reason) = repository.load() else {
            Issue.record("expected the future schema to be rejected")
            return
        }
        #expect(reason.contains("schemaVersion"))
    }

    @Test func emptyWindowListIsUnusable() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let empty = AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 1, windows: [])
        try SessionSnapshotRepository.encoder.encode(empty).write(to: repository.primaryURL)

        guard case .unusable(let reason) = repository.load() else {
            Issue.record("expected an empty window list to be rejected")
            return
        }
        #expect(reason.contains("noWindows"))
        // The graph is unusable, but the writer it names still owns the file.
        #expect(repository.storedOwner() == .init(ownerInstanceID: empty.ownerInstanceID, ownerPID: 1))
    }

    @Test func storedOwnerIsAbsentForMissingOrCorruptFiles() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        #expect(repository.storedOwner() == nil)
        try Data("{ not json".utf8).write(to: repository.primaryURL)
        #expect(repository.storedOwner() == nil)
    }

    @Test func corruptPrimaryFallsBackToBackup() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let good = makeSnapshot(ownerPID: 77)

        try SessionSnapshotRepository.encoder.encode(good).write(to: repository.backupURL)
        try Data("{ not json".utf8).write(to: repository.primaryURL)

        guard case .loaded(let loaded, let source) = repository.load() else {
            Issue.record("expected the backup to be used")
            return
        }
        #expect(source == .backup)
        #expect(loaded.ownerPID == 77)
    }

    @Test func bothSlotsCorruptIsUnusable() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        try Data("{ not json".utf8).write(to: repository.primaryURL)
        try Data("also not json".utf8).write(to: repository.backupURL)

        guard case .unusable = repository.load() else {
            Issue.record("expected both slots to be rejected")
            return
        }
    }

    // MARK: - Backup rotation

    @Test func firstSaveDoesNotRequireBackup() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        #expect(try repository.save(makeSnapshot()) == .written)

        #expect(!FileManager.default.fileExists(atPath: repository.backupURL.path))
    }

    @Test func changedSavesRotateTheImmediatelyPreviousValidPrimary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let first = makeSnapshot(ownerPID: 1)
        let second = makeSnapshot(ownerPID: 2)
        let third = makeSnapshot(ownerPID: 3)

        #expect(try repository.save(first) == .written)
        let firstBytes = try Data(contentsOf: repository.primaryURL)
        #expect(try repository.save(second) == .written)
        #expect(try Data(contentsOf: repository.backupURL) == firstBytes)
        #expect(repository.load() == .loaded(second, source: .primary))

        let secondBytes = try Data(contentsOf: repository.primaryURL)
        #expect(try repository.save(third) == .written)
        #expect(try Data(contentsOf: repository.backupURL) == secondBytes)
        #expect(repository.load() == .loaded(third, source: .primary))
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.backupURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        try Data("corrupt".utf8).write(to: repository.primaryURL)
        #expect(repository.load() == .loaded(second, source: .backup))
    }

    @Test func invalidPrimaryNeverOverwritesValidBackup() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let good = makeSnapshot()
        #expect(try repository.save(good) == .written)
        try repository.promotePrimaryToBackup()
        let backup = try Data(contentsOf: repository.backupURL)
        let empty = AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 1, windows: [])
        let depth = SessionSnapshotRepository.maxNestingDepth + 1
        let invalidFiles = [
            Data("corrupt".utf8),
            try SessionSnapshotRepository.encoder.encode(empty),
            Data(repeating: UInt8(ascii: " "), count: SessionSnapshotRepository.maxFileBytes + 1),
            Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        ]

        for invalid in invalidFiles {
            try invalid.write(to: repository.primaryURL)
            #expect(repository.load() == .loaded(good, source: .backup))
            #expect(throws: (any Error).self) { try repository.promotePrimaryToBackup() }
            #expect(try Data(contentsOf: repository.backupURL) == backup)
            let next = makeSnapshot()
            #expect(try repository.save(next) == .written)
            #expect(repository.load() == .loaded(next, source: .primary))
            #expect(try Data(contentsOf: repository.backupURL) == backup)
        }
    }

    @Test func backupWriteFailurePreservesPrimaryAndAllowsRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository(directory: directory)
        let first = makeSnapshot()
        let next = makeSnapshot()
        #expect(try repository.save(first) == .written)
        let primary = try Data(contentsOf: repository.primaryURL)
        let primaryDate = try modificationDate(repository.primaryURL)

        // A nonempty directory cannot be atomically replaced by backup bytes,
        // independent of the test process's filesystem permissions.
        try FileManager.default.createDirectory(at: repository.backupURL, withIntermediateDirectories: false)
        let blocker = repository.backupURL.appendingPathComponent("blocker")
        try Data("keep".utf8).write(to: blocker)
        #expect(throws: (any Error).self) { try repository.save(next) }
        #expect(try Data(contentsOf: repository.primaryURL) == primary)
        #expect(try modificationDate(repository.primaryURL) == primaryDate)
        #expect(repository.load() == .loaded(first, source: .primary))
        #expect(try Data(contentsOf: blocker) == Data("keep".utf8))

        try FileManager.default.removeItem(at: repository.backupURL)
        #expect(try repository.save(next) == .written)
        #expect(try Data(contentsOf: repository.backupURL) == primary)
        #expect(repository.load() == .loaded(next, source: .primary))
    }

    @Test func promotedBackupIsLoadedWhenPrimaryIsLaterCorrupted() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let booted = makeSnapshot(ownerPID: 4321)
        #expect(try repository.save(booted) == .written)

        try repository.promotePrimaryToBackup()
        #expect(FileManager.default.fileExists(atPath: repository.backupURL.path))

        // Whatever happens to the primary, the promoted file already booted
        // successfully at least once.
        try Data("corrupted".utf8).write(to: repository.primaryURL)

        guard case .loaded(let loaded, let source) = repository.load() else {
            Issue.record("expected the promoted backup to load")
            return
        }
        #expect(source == .backup)
        #expect(loaded.ownerPID == 4321)
    }

    @Test func promotionWithoutPrimaryIsNotAnError() throws {
        let repository = SessionSnapshotRepository(directory: try makeTemporaryDirectory())
        try repository.promotePrimaryToBackup()
        #expect(!FileManager.default.fileExists(atPath: repository.backupURL.path))
    }

    // MARK: - Validator

    @Test func workspaceWithoutTabsIsUnusable() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let snapshot = makeSnapshot(workspaces: [makeWorkspace(tabs: [])])
        try SessionSnapshotRepository.encoder.encode(snapshot).write(to: repository.primaryURL)

        guard case .unusable(let reason) = repository.load() else {
            Issue.record("expected a tabless workspace to be rejected")
            return
        }
        #expect(reason.contains("workspaceWithoutTabs"))
    }

    @Test func windowWithoutWorkspacesIsUnusable() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)
        let window = WindowSnapshot(physicalUUID: UUID(), selection: nil, workspaces: [])
        let snapshot = AppSessionSnapshot(
            ownerInstanceID: UUID(),
            ownerPID: 1,
            windows: [window]
        )
        try SessionSnapshotRepository.encoder.encode(snapshot).write(to: repository.primaryURL)

        guard case .unusable(let reason) = repository.load() else {
            Issue.record("expected a workspace-free window to be rejected")
            return
        }
        #expect(reason.contains("windowWithoutWorkspaces"))
    }

    @Test func duplicateTabIdentifiersAreUnusable() {
        let sharedID = UUID()
        let snapshot = makeSnapshot(workspaces: [
            makeWorkspace(tabs: [makeTab(id: sharedID), makeTab(id: sharedID)])
        ])

        guard case .failure(let rejection) = SessionSnapshotValidator.validate(snapshot) else {
            Issue.record("expected duplicate identifiers to be rejected")
            return
        }
        #expect(rejection == .duplicateIdentifier(sharedID))
    }

    @Test func paneTreeDeeperThanTheLimitIsUnusable() {
        var tree: PaneTreeSnapshot = .leaf(makeLeaf())
        for _ in 0...SessionSnapshotValidator.Limits.paneTreeDepth {
            tree = .split(direction: .vertical, ratio: 0.5, left: tree, right: .leaf(makeLeaf()))
        }
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: tree,
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let snapshot = makeSnapshot(workspaces: [makeWorkspace(tabs: [tab])])

        guard case .failure(let rejection) = SessionSnapshotValidator.validate(snapshot) else {
            Issue.record("expected an over-deep pane tree to be rejected")
            return
        }
        guard case .paneTreeTooDeep(let tabID, let depth) = rejection else {
            Issue.record("expected paneTreeTooDeep, got \(rejection)")
            return
        }
        #expect(tabID == tab.id)
        #expect(depth > SessionSnapshotValidator.Limits.paneTreeDepth)
    }

    @Test func ghostSelectionClampsToTheFirstTabRatherThanRejecting() throws {
        let realTab = makeTab()
        let workspace = makeWorkspace(tabs: [realTab], selectedTabID: UUID())
        let window = WindowSnapshot(
            physicalUUID: UUID(),
            selection: SelectionSnapshot(workspaceID: UUID(), tabID: UUID()),
            workspaces: [workspace]
        )
        let snapshot = AppSessionSnapshot(ownerInstanceID: UUID(), ownerPID: 1, windows: [window])

        guard case .success(let clamped) = SessionSnapshotValidator.validate(snapshot) else {
            Issue.record("a dangling selection should clamp, not reject")
            return
        }
        #expect(clamped.windows[0].workspaces[0].selectedTabID == realTab.id)
        #expect(clamped.windows[0].selection?.workspaceID == workspace.id)
        #expect(clamped.windows[0].selection?.tabID == realTab.id)
    }

    @Test func validSelectionIsPreserved() throws {
        let snapshot = makeSnapshot()
        let expected = try #require(snapshot.windows[0].selection)

        guard case .success(let validated) = SessionSnapshotValidator.validate(snapshot) else {
            Issue.record("expected a valid snapshot to pass")
            return
        }
        #expect(validated.windows[0].selection == expected)
    }

    // MARK: - Owner-field tolerance

    @Test func missingOwnerFieldsDecodeAsUnownedInsteadOfFailing() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)

        // Owner bookkeeping gone, workspaces intact. Losing the layout over it
        // would be the wrong trade.
        let snapshot = makeSnapshot()
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: try SessionSnapshotRepository.encoder.encode(snapshot)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "ownerInstanceID")
        object["ownerPID"] = "not-a-pid"
        try JSONSerialization.data(withJSONObject: object).write(to: repository.primaryURL)

        guard case .loaded(let loaded, let source) = repository.load() else {
            Issue.record("expected corrupt owner fields to be tolerated")
            return
        }
        #expect(source == .primary)
        #expect(loaded.ownerInstanceID == AppSessionSnapshot.unownedInstanceID)
        #expect(loaded.ownerPID == AppSessionSnapshot.unownedPID)
        #expect(loaded.windows.count == 1)
    }

    // MARK: - Hand-edited file defence

    @Test func nonFiniteOrOutOfRangeSplitRatioIsUnusable() {
        for ratio in [Double.nan, .infinity, -0.5, 0.0, 1.0, 42.0] {
            let tab = TabSnapshot(
                id: UUID(),
                titleOverride: nil,
                tabColor: nil,
                paneTree: .split(
                    direction: .horizontal,
                    ratio: ratio,
                    left: .leaf(makeLeaf()),
                    right: .leaf(makeLeaf())
                ),
                focusedPaneID: nil,
                zoomedPaneID: nil
            )
            let snapshot = makeSnapshot(workspaces: [makeWorkspace(tabs: [tab])])

            guard case .failure(let rejection) = SessionSnapshotValidator.validate(snapshot) else {
                Issue.record("ratio \(ratio) should be rejected")
                continue
            }
            guard case .invalidSplitRatio = rejection else {
                Issue.record("expected invalidSplitRatio for \(ratio), got \(rejection)")
                continue
            }
        }
    }

    @Test func ordinaryRatiosAreAccepted() {
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: .split(direction: .vertical, ratio: 0.5, left: .leaf(makeLeaf()), right: .leaf(makeLeaf())),
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let snapshot = makeSnapshot(workspaces: [makeWorkspace(tabs: [tab])])

        guard case .success = SessionSnapshotValidator.validate(snapshot) else {
            Issue.record("a normal ratio must pass")
            return
        }
    }

    @Test func absurdlyLongStringsAreUnusable() {
        // Character count alone is insufficient: this remains below the
        // character limit while exceeding the UTF-8 byte limit.
        let huge = String(
            repeating: "é",
            count: SessionSnapshotValidator.Limits.stringLength / 2 + 1
        )
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: nil,
            paneTree: .leaf(PaneLeafSnapshot(uuid: UUID(), cwd: huge, title: nil)),
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let snapshot = makeSnapshot(workspaces: [makeWorkspace(tabs: [tab])])

        guard case .failure(let rejection) = SessionSnapshotValidator.validate(snapshot) else {
            Issue.record("an oversized string should be rejected")
            return
        }
        guard case .stringTooLong(let field, _) = rejection else {
            Issue.record("expected stringTooLong, got \(rejection)")
            return
        }
        #expect(field == "pane.cwd")
    }

    @Test func absurdlyLongStoredTabColorIsUnusable() {
        let huge = String(repeating: "a", count: SessionSnapshotValidator.Limits.stringLength + 1)
        let tab = TabSnapshot(
            id: UUID(),
            titleOverride: nil,
            tabColor: huge,
            paneTree: .leaf(makeLeaf()),
            focusedPaneID: nil,
            zoomedPaneID: nil
        )
        let snapshot = makeSnapshot(workspaces: [makeWorkspace(tabs: [tab])])

        #expect(SessionSnapshotValidator.validate(snapshot) == .failure(
            .stringTooLong(field: "tab.tabColor", length: huge.utf8.count)
        ))
    }

    /// `JSONDecoder` recurses per level, so the value-level depth check never
    /// runs for a deeply nested file - the stack goes first. The byte scan has
    /// to reject it before decoding.
    @Test func deeplyNestedFileIsRejectedBeforeDecoding() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)

        let depth = SessionSnapshotRepository.maxNestingDepth + 50
        let bomb = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        try Data(bomb.utf8).write(to: repository.primaryURL)

        guard case .unusable(let reason) = repository.load() else {
            Issue.record("a nesting bomb must be rejected")
            return
        }
        #expect(reason.contains("limitExceeded kind=jsonNestingDepth count=\(depth)"))
    }

    @Test func nestingDepthIgnoresBracketsInsideStrings() {
        let json = #"{"a":"[[[[[["}"#
        #expect(SessionSnapshotRepository.nestingDepth(of: Data(json.utf8)) == 1)

        let escaped = #"{"a":"\"[[["}"#
        #expect(SessionSnapshotRepository.nestingDepth(of: Data(escaped.utf8)) == 1)

        let real = #"{"a":[{"b":[1]}]}"#
        #expect(SessionSnapshotRepository.nestingDepth(of: Data(real.utf8)) == 4)
    }

    @Test func oversizedFileIsRejectedBeforeDecoding() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)

        let padding = String(repeating: "x", count: SessionSnapshotRepository.maxFileBytes + 1)
        try Data(padding.utf8).write(to: repository.primaryURL)

        guard case .unusable(let reason) = repository.load() else {
            Issue.record("an oversized file must be rejected")
            return
        }
        #expect(reason.contains(
            "limitExceeded kind=fileBytes count=\(SessionSnapshotRepository.maxFileBytes + 1)"
        ))
    }

    @Test func missingVersionStillFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        let repository = SessionSnapshotRepository(directory: directory)

        var object = try #require(
            try JSONSerialization.jsonObject(
                with: try SessionSnapshotRepository.encoder.encode(makeSnapshot())
            ) as? [String: Any]
        )
        object.removeValue(forKey: "version")
        try JSONSerialization.data(withJSONObject: object).write(to: repository.primaryURL)

        guard case .unusable = repository.load() else {
            Issue.record("a file without a schema version must not be applied")
            return
        }
    }
}
