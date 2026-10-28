import Foundation
import Testing
@testable import Ghostty

struct SSHAskpassPromptClassifierTests {
    @Test func recognizesOnlyExactPasswordPromptWithoutMode() throws {
        let target = try target(user: "build@corp", hostName: "2001:db8::1")

        #expect(SSHAskpassPromptClassifier.classify(
            prompt: "build@corp@2001:db8::1's password: ",
            mode: nil,
            target: target) == .password)
    }

    @Test(arguments: [
        " build@corp@2001:db8::1's password: ",
        "build@corp@2001:db8::1's password:  ",
        "build@corp@2001:db8::1's password:",
        "Build@corp@2001:db8::1's password: ",
        "other@2001:db8::1's password: ",
        "build@corp@other's password: ",
        "gateway's password: ",
        "Verification code: ",
        "One-time password: ",
        "Enter passphrase for key '/tmp/id': ",
        "The authenticity of host 'host' can't be established. Continue connecting (yes/no)? ",
        "Keyboard-interactive authentication prompts from server:",
    ])
    func passesThroughNonExactPrompts(_ prompt: String) throws {
        let target = try target(user: "build@corp", hostName: "2001:db8::1")

        #expect(SSHAskpassPromptClassifier.classify(
            prompt: prompt,
            mode: nil,
            target: target) == .passthrough)
    }

    /// The host-key yes/no answer is visible; passwords and codes stay hidden.
    @Test(arguments: [
        ("Are you sure you want to continue connecting (yes/no/[fingerprint])? ", true),
        ("Are you sure you want to continue connecting (yes/no)? ", true),
        ("deploy@host's password: ", false),
        ("Verification code: ", false),
        ("Enter passphrase for key '/tmp/id': ", false),
    ])
    func echoesOnlyHostKeyAnswers(_ prompt: String, echoes: Bool) {
        #expect(prompt.withCString { SSHAskpassHelper.echoesAnswer(to: $0) } == echoes)
    }

    @Test(arguments: [Optional("confirm"), Optional(""), Optional("unknown")])
    func passesThroughAllNonNoneModes(_ mode: String?) throws {
        let target = try target()

        #expect(SSHAskpassPromptClassifier.classify(
            prompt: "deploy@host's password: ",
            mode: mode,
            target: target) == .passthrough)
    }

    @Test func noneModeAlwaysNotifies() throws {
        let target = try target()

        #expect(SSHAskpassPromptClassifier.classify(
            prompt: "deploy@host's password: ",
            mode: "none",
            target: target) == .notify)
        #expect(SSHAskpassPromptClassifier.classify(
            prompt: "Verification code: ",
            mode: "none",
            target: target) == .notify)
    }

    @Test func requiresUTF8ByteExactMatch() throws {
        let composedTarget = try target(user: "café", hostName: "host")
        let decomposedPrompt = "cafe\u{301}@host's password: "

        #expect(SSHAskpassPromptClassifier.classify(
            prompt: decomposedPrompt,
            mode: nil,
            target: composedTarget) == .passthrough)
    }

    private func target(
        user: String = "deploy",
        hostName: String = "host"
    ) throws -> SSHTargetFingerprint {
        try SSHTargetFingerprint(hostID: UUID(), user: user, hostName: hostName, port: 22)
    }
}
