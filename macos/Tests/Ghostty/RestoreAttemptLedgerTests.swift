import Foundation
import Darwin
import Testing
@testable import Ghostty

@MainActor
@Suite struct RestoreAttemptLedgerTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-attempts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gate() -> SessionPersistenceGate {
        SessionPersistenceGate(environment: [:], arguments: [], configEnabled: true)
    }

    private func controller(
        _ directory: URL,
        instance: UUID = UUID(),
        pid: Int32 = 71,
        live: @escaping (Int32) -> Bool = { _ in false },
        uptime: @escaping () -> UInt64 = { 100 }
    ) -> SessionPersistenceController {
        SessionPersistenceController(
            repository: SessionSnapshotRepository(directory: directory),
            gate: gate(),
            registry: PendingHydrationRegistry(),
            ownerInstanceID: instance,
            ownerPID: pid,
            isLiveInstance: live,
            uptime: uptime,
            controllersProvider: { [] }
        )
    }

    private func token(
        _ controller: SessionPersistenceController,
        target: UUID
    ) throws -> SessionPersistenceController.RestoreAttemptToken {
        let start = controller.beginRestoreAttempt(.tab, [target])
        guard case .recorded(let token) = start else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }

    @Test func aFinishedAttemptLeavesNoEntry() throws {
        let directory = try directory()
        let persistence = controller(directory)
        let token = try token(persistence, target: UUID())
        persistence.finishRestoreAttempt(token)
        #expect(SessionSnapshotRepository(directory: directory).restoreAttempts().isEmpty)
    }

    @Test func anAttemptOfALiveProcessIsNotQuarantine() throws {
        let directory = try directory()
        let persistence = controller(directory, live: { $0 == 99 })
        let repository = SessionSnapshotRepository(directory: directory)
        let id = UUID()
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: id, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 99, startedAtUptime: 1))
        }
        #expect(!persistence.restoreQuarantine().tabs.contains(id))
    }

    @Test func anAttemptOfADeadProcessIsQuarantine() throws {
        let directory = try directory()
        let persistence = controller(directory)
        let repository = SessionSnapshotRepository(directory: directory)
        let id = UUID()
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: id, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 99, startedAtUptime: 1))
        }
        #expect(persistence.restoreQuarantine().tabs.contains(id))
    }

    @Test func anAttemptFromAPreviousBootIsQuarantine() throws {
        let directory = try directory()
        let persistence = controller(directory, live: { _ in true }, uptime: { 10 })
        let repository = SessionSnapshotRepository(directory: directory)
        let id = UUID()
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: id, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 99, startedAtUptime: 11))
        }
        #expect(persistence.restoreQuarantine().tabs.contains(id))
    }

    @Test func finishingOneAttemptNeverClearsAnotherProcesssAttemptOnTheSameTarget() throws {
        let directory = try directory()
        let peerPID: Int32 = 2
        let first = controller(directory, instance: UUID(), pid: 1, live: { $0 == peerPID })
        let second = controller(directory, instance: UUID(), pid: peerPID)
        let target = UUID()
        let otherTarget = UUID()
        let firstToken = try token(first, target: target)
        let peerToken = try token(second, target: target)
        let otherToken = try token(second, target: otherTarget)
        first.finishRestoreAttempt(firstToken, recovered: [target])
        let attempts = SessionSnapshotRepository(directory: directory).restoreAttempts()
        #expect(attempts.map(\.attemptID).contains(peerToken.attemptID))
        #expect(attempts.map(\.attemptID).contains(otherToken.attemptID))
    }

    @Test func aSuccessfulRetryLiftsTheDeadEntriesOfItsTarget() throws {
        let directory = try directory()
        let persistence = controller(directory)
        let repository = SessionSnapshotRepository(directory: directory)
        let target = UUID()
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: target, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 99, startedAtUptime: 1))
        }
        let retry = try token(persistence, target: target)
        persistence.finishRestoreAttempt(retry, recovered: [target])
        #expect(repository.restoreAttempts().isEmpty)
    }

    @Test func anAbandonedAttemptRemovesOnlyItsOwnEntry() throws {
        let directory = try directory()
        let persistence = controller(directory)
        let repository = SessionSnapshotRepository(directory: directory)
        let target = UUID()
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: target, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 99, startedAtUptime: 1))
        }
        let retry = try token(persistence, target: target)
        persistence.finishRestoreAttempt(retry)
        #expect(repository.restoreAttempts().count == 1)
    }

    @Test func normalQuitRemovesOnlyThisInstancesEntries() throws {
        let directory = try directory()
        let persistence = controller(directory, instance: UUID(), pid: 1)
        let repository = SessionSnapshotRepository(directory: directory)
        _ = try token(persistence, target: UUID())
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: UUID(), attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 2, startedAtUptime: 1))
        }
        persistence.finishOwnRestoreAttempts()
        #expect(repository.restoreAttempts().count == 1)
    }

    @Test func pruningDropsDeadEntriesForTargetsNoLongerStored() throws {
        let directory = try directory()
        let persistence = controller(directory)
        let repository = SessionSnapshotRepository(directory: directory)
        let stale = UUID()
        let kept = UUID()
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: stale, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 2, startedAtUptime: 1))
            attempts.append(.init(kind: .tab, targetID: kept, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 2, startedAtUptime: 1))
        }
        persistence.pruneRestoreAttempts(keeping: [kept])
        #expect(repository.restoreAttempts().map(\.targetID) == [kept])
    }

    @Test func closedGateNeverCreatesTheAttemptsFile() throws {
        let directory = try directory()
        let persistence = SessionPersistenceController(
            repository: SessionSnapshotRepository(directory: directory),
            gate: SessionPersistenceGate(environment: ["XCTestConfigurationFilePath": "test"], arguments: [], configEnabled: true),
            registry: PendingHydrationRegistry(),
            controllersProvider: { [] }
        )
        #expect(persistence.beginRestoreAttempt(.tab, [UUID()]) == .notTracked)
        persistence.finishRestoreAttempt(.init(
            attemptID: UUID(),
            kind: .tab,
            targetIDs: [UUID()]
        ))
        persistence.finishOwnRestoreAttempts()
        persistence.pruneRestoreAttempts(keeping: [])
        _ = persistence.restoreQuarantine()
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    @Test func aWriteFailureIsReportedAsUnrecordedNotDisabled() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(SessionSnapshotRepository.restoreAttemptsLockFileName), withIntermediateDirectories: true)
        let persistence = SessionPersistenceController(repository: repository, gate: gate(), registry: PendingHydrationRegistry(), controllersProvider: { [] })
        #expect(persistence.beginRestoreAttempt(.tab, [UUID()]) == .unrecorded)
        #expect(persistence.restoreAttemptsUnavailable)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(SessionSnapshotRepository.restoreAttemptsLockFileName))
        let start = persistence.beginRestoreAttempt(.tab, [UUID()])
        guard case .recorded = start else {
            Issue.record("Expected a recorded retry")
            return
        }
        #expect(!persistence.restoreAttemptsUnavailable)
    }

    @Test func lockUnsupportedFallsBackToAnUnlockedUpdate() throws {
        let directory = try directory()
        let repository = SessionSnapshotRepository(directory: directory, restoreAttemptsLock: { _, _ in
            errno = ENOTSUP
            return -1
        })
        let target = UUID()
        try repository.updateRestoreAttempts { attempts in
            attempts.append(.init(kind: .tab, targetID: target, attemptID: UUID(), ownerInstanceID: UUID(), ownerPID: 1, startedAtUptime: 1))
        }
        #expect(repository.restoreAttempts().map(\.targetID) == [target])
    }
}
