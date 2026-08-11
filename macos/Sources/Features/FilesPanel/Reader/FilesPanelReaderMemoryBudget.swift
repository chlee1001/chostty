import Foundation
import os

final class FilesPanelReaderMemoryBudget: @unchecked Sendable {
    static let maximumDecodedBytes = 64 * 1024 * 1024

    private struct Entry {
        var bytes: Int
        var lastAccess: UInt64
        let evict: @Sendable () -> Void
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        var clock: UInt64 = 0
    }

    private let maximumBytes: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maximumBytes: Int = maximumDecodedBytes) {
        self.maximumBytes = maximumBytes
    }

    func register(id: UUID, evict: @escaping @Sendable () -> Void) {
        state.withLock { value in
            value.entries[id] = Entry(bytes: value.entries[id]?.bytes ?? 0, lastAccess: value.clock, evict: evict)
        }
    }

    func unregister(id: UUID) {
        state.withLock { $0.entries.removeValue(forKey: id) }
    }

    @discardableResult
    func reserve(_ bytes: Int, for id: UUID) -> Bool {
        var evictions: [@Sendable () -> Void] = []
        let accepted = state.withLock { value -> Bool in
            guard var entry = value.entries[id], bytes <= maximumBytes else { return false }
            value.clock &+= 1
            entry.bytes = bytes
            entry.lastAccess = value.clock
            value.entries[id] = entry

            while value.entries.values.reduce(0, { $0 + $1.bytes }) > maximumBytes {
                guard let victim = value.entries
                    .filter({ $0.key != id && $0.value.bytes > 0 })
                    .min(by: { $0.value.lastAccess < $1.value.lastAccess }) else {
                    entry.bytes = 0
                    value.entries[id] = entry
                    return false
                }
                var victimEntry = victim.value
                victimEntry.bytes = 0
                value.entries[victim.key] = victimEntry
                evictions.append(victimEntry.evict)
            }
            return true
        }
        evictions.forEach { $0() }
        return accepted
    }

    func release(id: UUID) {
        state.withLock { value in
            guard var entry = value.entries[id] else { return }
            entry.bytes = 0
            value.entries[id] = entry
        }
    }

    var currentUsedBytes: Int {
        state.withLock { $0.entries.values.reduce(0, { $0 + $1.bytes }) }
    }
}
