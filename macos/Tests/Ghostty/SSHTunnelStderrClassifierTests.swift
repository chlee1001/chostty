import Testing
@testable import Ghostty

struct SSHTunnelStderrClassifierTests {
    @Test func classifiesDefaultLevelAppleOpenSSHSamples() {
        #expect(SSHTunnelStderrClassifier.classify(
            stderr: "tunnel-auth-test@127.0.0.1: Permission denied (publickey).\n", exitStatus: 255
        ) == .authRequired)
        #expect(SSHTunnelStderrClassifier.classify(
            stderr: "No ED25519 host key is known for [127.0.0.1]:60571 and you have requested strict checking.\nHost key verification failed.\n",
            exitStatus: 255
        ) == .hostKeyUnknown)
        #expect(SSHTunnelStderrClassifier.classify(
            stderr: "bind [127.0.0.1]:60574: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 60574\nCould not request local forwarding.\n",
            exitStatus: 255
        ) == .localPortInUse)
        #expect(SSHTunnelStderrClassifier.classify(
            stderr: "Error: remote port forwarding failed for listen port 0\n", exitStatus: 255
        ) == .forwardRejected)
        #expect(SSHTunnelStderrClassifier.classify(
            stderr: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.\n", exitStatus: 255
        ) == .hostKeyChanged)
    }

    @Test func aChangedKeyWinsOverTheGenericVerificationError() {
        let sample = "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.\n"
        #expect(SSHTunnelStderrClassifier.classify(stderr: sample, exitStatus: 255) == .hostKeyChanged)
        #expect(SSHTunnelStderrClassifier.classify(stderr: "channel 5: open failed: connect failed", exitStatus: 255)
                == .exited(255))
        #expect(SSHTunnelFailure.authRequired.message
                == "Interactive authentication is unavailable right now. Use a key or agent.")
        #expect(SSHTunnelFailure.hostKeyUnknown.message == "Connect once in a terminal tab to trust this host.")
    }

    @Test func anInteractiveTunnelReportsTheUsersAnswer() {
        let refused = "Host key verification failed.\r\n"
        #expect(SSHTunnelStderrClassifier.classify(stderr: refused, exitStatus: 255, interactive: true)
                == .authentication("The host key was not trusted."))
        let denied = "user@example.com: Permission denied (publickey,password).\r\n"
        #expect(SSHTunnelStderrClassifier.classify(stderr: denied, exitStatus: 255, interactive: true)
                == .authentication("SSH authentication failed."))
        let changed = "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.\n"
        #expect(SSHTunnelStderrClassifier.classify(stderr: changed, exitStatus: 255, interactive: true)
                == .hostKeyChanged)
    }
}
