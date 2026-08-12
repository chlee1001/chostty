import Foundation
import Testing
@testable import Ghostty

struct TerminalReaderStoreBudgetTests {
    @Test func evictsOldestOtherReservationBeforeExceedingLimit() {
        let budget = FilesPanelReaderMemoryBudget(maximumBytes: 10)
        let first = UUID()
        let second = UUID()
        let eviction = Flag()
        budget.register(id: first) { eviction.set() }
        budget.register(id: second) {}

        #expect(budget.reserve(6, for: first))
        #expect(budget.reserve(6, for: second))
        #expect(eviction.value)
        #expect(budget.currentUsedBytes == 6)
    }

    @Test func rejectsSingleReservationLargerThanLimit() {
        let budget = FilesPanelReaderMemoryBudget(maximumBytes: 10)
        let id = UUID()
        budget.register(id: id) {}
        #expect(!budget.reserve(11, for: id))
        #expect(budget.currentUsedBytes == 0)
    }

    @Test func protectedReservationIsNeverEvicted() {
        let budget = FilesPanelReaderMemoryBudget(maximumBytes: 10)
        let selected = UUID()
        let background = UUID()
        let selectedEviction = Flag()
        budget.register(id: selected) { selectedEviction.set() }
        budget.register(id: background) {}

        #expect(budget.reserve(7, for: selected))
        #expect(!budget.reserve(7, for: background, protecting: selected))
        #expect(!selectedEviction.value)
        #expect(budget.currentUsedBytes == 7)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
    }
}
