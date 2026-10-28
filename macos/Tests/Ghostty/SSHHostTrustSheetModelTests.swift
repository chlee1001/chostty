import Foundation
import Testing
@testable import Ghostty

struct SSHHostTrustSheetModelTests {
    private let question = """
        The authenticity of host 'db.example.test (192.0.2.10)' can't be established.
        ED25519 key fingerprint is SHA256:Wm5z2nJ3hQ0FzVqk2r1kq7l3Q0cU3d9r6b7s8t9u0v1.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """

    @Test func aQuestionAboutTheResolvedDestinationHasNoWarning() {
        let model = SSHHostTrustSheetModel(prompt: question, alias: "db", hostName: "DB.example.test", port: 22)
        #expect(model.destination == "DB.example.test:22")
        #expect(model.promptHost == "db.example.test")
        #expect(model.fingerprint == "SHA256:Wm5z2nJ3hQ0FzVqk2r1kq7l3Q0cU3d9r6b7s8t9u0v1")
        #expect(model.warning == nil)
    }

    @Test func aQuestionAboutAnotherHostIsFlagged() {
        let model = SSHHostTrustSheetModel(prompt: question, alias: "db", hostName: "bastion.example.test", port: 22)
        #expect(model.warning != nil)
        #expect(model.warning == "SSH is asking about db.example.test:22, not bastion.example.test:22.")
    }

    @Test func aNonDefaultPortIsReadFromTheBrackets() {
        let prompt = question.replacingOccurrences(
            of: "'db.example.test (192.0.2.10)'", with: "'[db.example.test]:2222 ([192.0.2.10]:2222)'")
        let matching = SSHHostTrustSheetModel(prompt: prompt, alias: "db", hostName: "db.example.test", port: 2222)
        #expect(matching.promptHost == "db.example.test:2222")
        #expect(matching.warning == nil)
        let wrongPort = SSHHostTrustSheetModel(prompt: prompt, alias: "db", hostName: "db.example.test", port: 22)
        #expect(wrongPort.warning != nil)
    }

    @Test func anUnresolvedOrUnnamedHostStillWarns() {
        let unresolved = SSHHostTrustSheetModel(prompt: question, alias: "db", hostName: nil, port: nil)
        #expect(unresolved.destination == nil)
        #expect(unresolved.warning == "Chostty couldn't confirm the HostName and Port for this alias.")
        let unnamed = SSHHostTrustSheetModel(
            prompt: "Are you sure you want to continue connecting (yes/no)?",
            alias: "db", hostName: "db.example.test", port: 22)
        #expect(unnamed.fingerprint == nil)
        #expect(unnamed.warning == "SSH didn't name the host it is asking about.")
    }

    @Test func conflictingKeyQuestionsAreRecognized() {
        #expect(!SSHHostTrustSheetModel.reportsConflict(question))
        #expect(SSHHostTrustSheetModel.reportsConflict(
            "The authenticity of host 'db (192.0.2.10)' can't be established\n"
                + "but keys of different type are already known for this host.\n"
                + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
        #expect(SSHHostTrustSheetModel.reportsConflict(
            "Warning: the ED25519 host key for 'db' differs from the key for the IP address '192.0.2.10'\n"
                + "Are you sure you want to continue connecting (yes/no)? "))
        #expect(SSHHostTrustSheetModel.reportsConflict(
            "No matching host key fingerprint found in DNS.\n" + question))
    }

    @Test func theSheetKeepsSSHsQuestionAndCautionsWithoutAFingerprint() {
        let model = SSHHostTrustSheetModel(prompt: question, alias: "db", hostName: "db.example.test", port: 22)
        #expect(model.question == question)
        #expect(!model.needsCaution)
        let unnamed = SSHHostTrustSheetModel(
            prompt: "The authenticity of host 'db.example.test' can't be established.\n"
                + "Are you sure you want to continue connecting (yes/no)?",
            alias: "db", hostName: "db.example.test", port: 22)
        #expect(unnamed.warning == nil)
        #expect(unnamed.needsCaution)
    }

    @Test func theOnlyRepliesAreYesAndNo() {
        let model = SSHHostTrustSheetModel(prompt: question, alias: "db", hostName: "db.example.test", port: 22)
        #expect(model.reply(trusted: true) == "yes")
        #expect(model.reply(trusted: false) == "no")
    }

    @Test func promptsAreSortedByModeAndQuestion() {
        #expect(SSHTunnelPrompt(prompt: question, mode: nil) == .hostKey(question))
        #expect(SSHTunnelPrompt(prompt: "alice@db's password: ", mode: nil) == .input("alice@db's password: "))
        #expect(SSHTunnelPrompt(prompt: "Allow use of key?", mode: "confirm") == .confirmation("Allow use of key?"))
        #expect(SSHTunnelPrompt(prompt: "Confirm user presence", mode: "none") == .notice("Confirm user presence"))
        // A host-key question with a mode is not treated as one.
        #expect(SSHTunnelPrompt(prompt: question, mode: "confirm") == .confirmation(question))
    }
}
