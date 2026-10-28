import Testing
@testable import Ghostty

struct SSHAskpassEntryTests {
    @Test func acceptsOnlyHelperInvocationShape() {
        let environment = [
            "CHOSTTY_ASKPASS_TOKEN": "token",
            "CHOSTTY_ASKPASS_SOCKET": "/tmp/socket",
        ]

        #expect(SSHAskpassEntry.isHelperInvocation(
            arguments: ["/path/askpass", "deploy@host's password: "],
            environment: environment))
        #expect(SSHAskpassEntry.isHelperInvocation(
            arguments: ["/path/askpass", "prompt"],
            environment: [
                "CHOSTTY_ASKPASS_TOKEN": "",
                "CHOSTTY_ASKPASS_SOCKET": "",
            ]))
    }

    @Test func rejectsMissingRequiredEnvironmentKeys() {
        #expect(!SSHAskpassEntry.isHelperInvocation(
            arguments: ["/path/askpass", "prompt"],
            environment: [:]))
        #expect(!SSHAskpassEntry.isHelperInvocation(
            arguments: ["/path/askpass", "prompt"],
            environment: ["CHOSTTY_ASKPASS_TOKEN": "token"]))
        #expect(!SSHAskpassEntry.isHelperInvocation(
            arguments: ["/path/askpass", "prompt"],
            environment: ["CHOSTTY_ASKPASS_SOCKET": "/tmp/socket"]))
    }

    // Inherited askpass variables cannot divert an ordinary app or +ssh launch.
    @Test func inheritedAskpassEnvironmentDoesNotBecomeAHelperInvocation() {
        let environment = [
            "SSH_ASKPASS": "/tmp/inherited-askpass",
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ":inherited-display",
            "CHOSTTY_ASKPASS_TOKEN": "inherited-token",
            "CHOSTTY_ASKPASS_SOCKET": "/tmp/inherited-askpass.sock",
            "CHOSTTY_ASKPASS_TUNNEL": "1",
        ]

        #expect(!SSHAskpassEntry.isHelperInvocation(
            arguments: ["/Applications/Chostty.app/Contents/MacOS/Chostty"],
            environment: environment))
        #expect(!SSHAskpassEntry.isHelperInvocation(
            arguments: ["/Applications/Chostty.app/Contents/MacOS/Chostty", "+ssh", "--", "host"],
            environment: environment))
    }

    @Test(arguments: [
        [],
        ["/path/askpass"],
        ["/path/askpass", "prompt", "extra"],
        ["/path/askpass", "+ssh"],
        ["/path/askpass", "+version"],
    ])
    func rejectsNonHelperArgumentShapes(_ arguments: [String]) {
        #expect(!SSHAskpassEntry.isHelperInvocation(
            arguments: arguments,
            environment: [
                "CHOSTTY_ASKPASS_TOKEN": "token",
                "CHOSTTY_ASKPASS_SOCKET": "/tmp/socket",
            ]))
    }

    @Test func acceptsOrdinaryPrompt() {
        #expect(SSHAskpassEntry.isHelperInvocation(
            arguments: ["/path/askpass", "Password for host:"],
            environment: [
                "CHOSTTY_ASKPASS_TOKEN": "token",
                "CHOSTTY_ASKPASS_SOCKET": "/tmp/socket",
            ]))
    }
}
