import Foundation

enum SSHAskpassPromptClassifier {
    enum Classification: Equatable, Sendable {
        case password
        case passthrough
        case notify
    }

    static func classify(
        prompt: String,
        mode: String?,
        target: SSHTargetFingerprint
    ) -> Classification {
        switch mode {
        case "none":
            return .notify
        case .some:
            return .passthrough
        case nil:
            break
        }

        let expected = "\(target.user)@\(target.hostName)'s password: "
        return prompt.utf8.elementsEqual(expected.utf8) ? .password : .passthrough
    }
}
