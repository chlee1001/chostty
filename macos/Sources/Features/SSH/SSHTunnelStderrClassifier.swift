import Foundation

enum SSHTunnelFailure: Equatable, Sendable {
    case authRequired
    case hostKeyUnknown
    case localPortInUse
    case forwardRejected
    case hostKeyChanged
    case exited(Int32)
    case authentication(String)

    var message: String {
        switch self {
        case .authRequired:
            return "Interactive authentication is unavailable right now. Use a key or agent."
        case .hostKeyUnknown:
            return "Connect once in a terminal tab to trust this host."
        case .localPortInUse:
            return "The local port is already in use."
        case .forwardRejected:
            return "The SSH server rejected this forwarding request."
        case .hostKeyChanged:
            return "The SSH host key changed. This tunnel was stopped."
        case .exited(let status):
            return "SSH exited (status \(status))."
        case .authentication(let message):
            return message
        }
    }
}

enum SSHTunnelStderrClassifier {
    static let channelFailureMessage = "The last forwarded connection could not reach the target."

    /// A refused target is a per-channel failure (`channel N: open failed: …`);
    /// the tunnel itself stays up.
    static func containsChannelFailure(_ stderr: String) -> Bool {
        stderr.contains(": open failed: ")
    }

    static let hostKeyNotTrustedMessage = "The host key was not trusted."
    static let authenticationFailedMessage = "SSH authentication failed."

    /// `interactive` tunnels could prompt, so a refused key or login was the
    /// user's answer rather than a missing one.
    static func classify(stderr: String, exitStatus: Int32, interactive: Bool = false) -> SSHTunnelFailure {
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return .hostKeyChanged
        }
        if stderr.contains("remote port forwarding failed") {
            return .forwardRejected
        }
        if stderr.contains("Address already in use") {
            return .localPortInUse
        }
        if stderr.contains("Host key verification failed.") {
            return interactive ? .authentication(hostKeyNotTrustedMessage) : .hostKeyUnknown
        }
        if stderr.contains("Permission denied (") {
            return interactive ? .authentication(authenticationFailedMessage) : .authRequired
        }
        return .exited(exitStatus)
    }
}
