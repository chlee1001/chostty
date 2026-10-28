import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SSHSupervisorLoopTests {
    @Test func waitingInputIsDiscardedUntilAnIsolatedReturnRequestsConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let received = directory.appendingPathComponent("received")
        let started = directory.appendingPathComponent("started")
        let fixture = try SupervisorFixture(autoConnect: false, fakeSSH: """
            #!/bin/sh
            : >'\(started.path)'
            stty -icanon -isig min 0 time 2
            dd bs=1024 count=1 >'\(received.path)' 2>/dev/null || :
            sleep 1
            exit 255
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.waiting(sequence: 0))
        try fixture.waitForOutput("\u{1B}[?2004h")
        fixture.writeToTerminal("\u{1B}[200~paste\n\u{1B}[201~plain\n한글\u{3}\u{1A}")
        // `min 0 time 1` needs one quiet decisecond to establish an isolated
        // Return boundary after the deliberately multi-byte discarded input.
        usleep(300_000)
        #expect(fixture.currentState == .waiting(sequence: 0))
        #expect(!FileManager.default.fileExists(atPath: started.path))

        fixture.writeToTerminal("\r")
        try fixture.waitForState(.connectRequested(sequence: 0))
        fixture.sendControl("connect 1 -\n")
        try fixture.waitForOutput("\u{1B}[?2004l")
        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: true))
        #expect(try String(contentsOf: received, encoding: .utf8).isEmpty)
    }

    @Test func reconnectRestoresBaseModeBeforeAuthentication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let count = directory.appendingPathComponent("count")
        let fixture = try SupervisorFixture(fakeSSH: """
            #!/bin/sh
            count=$(cat '\(count.path)' 2>/dev/null || printf 0)
            count=$((count + 1))
            printf '%s' "$count" >'\(count.path)'
            if [ "$count" = 1 ]; then
                stty -icanon -isig min 1 time 0
                sleep 1
                exit 255
            fi
            stty -a | grep -q -- '-icanon' && exit 88
            printf 'SECOND-AUTH-CANONICAL\\n'
            sleep 1
            stty -icanon -isig min 1 time 0
            sleep 1
            exit 0
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.connected(sequence: 1))
        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: true))
        fixture.writeToTerminal("\n")
        try fixture.waitForState(.connectRequested(sequence: 1))

        fixture.sendControl("connect 2 -\n")
        try fixture.waitForState(.connecting(sequence: 2))
        try fixture.waitForOutput("SECOND-AUTH-CANONICAL")
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("ever").path))
        try fixture.waitForState(.connected(sequence: 2))
        try fixture.waitForState(.exited(sequence: 2, status: 0, everConnected: true))
        #expect(try fixture.waitForExit() == 0)
    }

    @Test func connectingWaitsForTheWaitingReaderBeforeHandingInputToSSH() throws {
        let fixture = try SupervisorFixture(autoConnect: false, fakeSSH: """
            #!/bin/sh
            printf 'AUTH-READY\\n'
            IFS= read -r authentication
            printf 'AUTH:%s\\n' "$authentication"
            exit 255
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.waiting(sequence: 0))
        fixture.writeToTerminal("\r")
        try fixture.waitForState(.connectRequested(sequence: 0))

        fixture.sendControl("connect 1 -\n")
        try fixture.waitForState(.connecting(sequence: 1))
        try fixture.waitForOutput("AUTH-READY")
        fixture.writeToTerminal("authentication\n")
        try fixture.waitForOutput("AUTH:authentication")
        try fixture.waitForState(.exited(sequence: 1, status: 255, everConnected: false))
    }

    @Test func denyRearmsReturnWithANewSequenceWithoutReconnect() throws {
        let fixture = try SupervisorFixture(autoConnect: false, fakeSSH: """
            #!/bin/sh
            printf 'FAKE-SSH-STARTED\\n'
            exit 255
            """)
        defer { fixture.stop() }

        try fixture.waitForState(.waiting(sequence: 0))
        fixture.writeToTerminal("\r")
        try fixture.waitForState(.connectRequested(sequence: 0))

        fixture.sendControl("deny 1 hostRemoved\n")
        try fixture.waitForState(.waiting(sequence: 1))
        fixture.sendControl("connect 1 -\n")
        usleep(100_000)
        #expect(fixture.currentState == .waiting(sequence: 1))
        #expect(!fixture.output.contains("FAKE-SSH-STARTED"))
        fixture.writeToTerminal("\r")
        try fixture.waitForState(.connectRequested(sequence: 1))

        fixture.sendControl("connect 2 -\n")
        try fixture.waitForOutput("FAKE-SSH-STARTED")
        try fixture.waitForState(.exited(sequence: 2, status: 255, everConnected: false))
        usleep(100_000)
        #expect(fixture.currentState == .exited(sequence: 2, status: 255, everConnected: false))
    }
}
