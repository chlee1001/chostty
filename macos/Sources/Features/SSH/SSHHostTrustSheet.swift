import AppKit
import Darwin
import Foundation

/// What a tunnel's ssh asked for. A tunnel has no terminal, so each kind is
/// answered in the app instead.
enum SSHTunnelPrompt: Equatable, Sendable {
    /// ssh's first-connection question about an unknown host key.
    case hostKey(String)
    /// `SSH_ASKPASS_PROMPT=confirm`: allowed or not, never typed.
    case confirmation(String)
    /// `SSH_ASKPASS_PROMPT=none`: a message such as "touch your security key".
    case notice(String)
    /// Anything to type: a password, a verification code, a passphrase.
    case input(String)

    init(prompt: String, mode: String?) {
        switch mode {
        case "none": self = .notice(prompt)
        case "confirm": self = .confirmation(prompt)
        default: self = SSHHostTrustSheetModel.isHostKeyQuestion(prompt) ? .hostKey(prompt) : .input(prompt)
        }
    }

    var text: String {
        switch self {
        case .hostKey(let text), .confirmation(let text), .notice(let text), .input(let text): text
        }
    }
}

/// The host-key question for a tunnel, next to the destination Chostty
/// resolved for its alias. The only replies are `yes` and `no`; the app never
/// edits `known_hosts` itself. A question that reports a conflict with a known
/// key never reaches the sheet (see `reportsConflict`).
struct SSHHostTrustSheetModel: Equatable {
    let alias: String
    /// ssh's question, shown as ssh wrote it.
    let question: String
    /// `HostName:Port` from `ssh -G`, when it could be resolved.
    let destination: String?
    /// The key fingerprint quoted from ssh's question.
    let fingerprint: String?
    /// The host ssh named in its question.
    let promptHost: String?
    /// Why the question may not be about this alias's destination.
    let warning: String?

    /// Shown with a critical alert: the question may not be about this alias,
    /// or ssh did not show which key it is.
    var needsCaution: Bool { warning != nil || fingerprint == nil }

    init(prompt: String, alias: String, hostName: String?, port: Int?) {
        self.alias = alias
        question = prompt
        let named = Self.host(in: prompt)
        promptHost = named.map { $0.port == 22 ? $0.name : "\($0.name):\($0.port)" }
        fingerprint = Self.fingerprint(in: prompt)
        guard let hostName, let port else {
            destination = nil
            warning = "Chostty couldn't confirm the HostName and Port for this alias."
            return
        }
        destination = "\(hostName):\(port)"
        if let named {
            warning = named.name.lowercased() == hostName.lowercased() && named.port == port
                ? nil
                : "SSH is asking about \(named.name):\(named.port), not \(hostName):\(port)."
        } else {
            warning = "SSH didn't name the host it is asking about."
        }
    }

    static func isHostKeyQuestion(_ prompt: String) -> Bool {
        prompt.contains("Are you sure you want to continue connecting (yes/no")
    }

    /// ssh asks the same question when a known key conflicts with the offered
    /// one: another key type is already known, the IP address has a different
    /// key, or DNS disagrees. Trusting would accept a key ssh warned about, so
    /// the tunnel answers `no` without asking.
    static func reportsConflict(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        return [
            "keys of different type are already known",
            "differs from the key for the ip address",
            "no matching host key fingerprint found in dns",
            "warning:",
        ].contains { lowered.contains($0) }
    }

    func reply(trusted: Bool) -> String {
        trusted ? "yes" : "no"
    }

    /// OpenSSH writes `host 'name (address)'`, with `[name]:port` for a
    /// non-default port.
    private static func host(in prompt: String) -> (name: String, port: Int)? {
        guard let open = prompt.range(of: "host '"),
              let close = prompt[open.upperBound...].firstIndex(of: "'")
        else { return nil }
        var named = prompt[open.upperBound..<close]
        if let address = named.range(of: " (") { named = named[..<address.lowerBound] }
        if named.hasPrefix("["), let end = named.range(of: "]:") {
            guard let port = Int(named[end.upperBound...]) else { return nil }
            let name = named[named.index(after: named.startIndex)..<end.lowerBound]
            return name.isEmpty ? nil : (String(name), port)
        }
        return named.isEmpty ? nil : (String(named), 22)
    }

    private static func fingerprint(in prompt: String) -> String? {
        let marker = " key fingerprint is "
        for line in prompt.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: marker) else { continue }
            var value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(".") { value.removeLast() }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// One tunnel prompt shown as a sheet. The reply goes straight to the broker
/// and is never stored.
@MainActor
final class SSHTunnelPromptSheet {
    private let prompt: SSHTunnelPrompt
    private let trust: SSHHostTrustSheetModel?
    private let alert = NSAlert()
    private let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    private weak var parent: NSWindow?
    private var completion: ((SSHSecretBuffer?) -> Void)?

    /// - Parameter trust: the host-key model, required for `.hostKey`.
    init(
        _ prompt: SSHTunnelPrompt,
        tunnelName: String,
        trust: SSHHostTrustSheetModel?,
        completion: @escaping (SSHSecretBuffer?) -> Void
    ) {
        self.prompt = prompt
        self.trust = trust
        self.completion = completion
        switch prompt {
        case .hostKey:
            alert.messageText = "Trust the host key for \(trust?.alias ?? tunnelName)?"
            alert.informativeText = Self.trustText(trust)
            alert.alertStyle = trust?.needsCaution == false ? .warning : .critical
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
            // Return must not trust a key; Cancel is the default button.
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        case .confirmation(let text):
            alert.messageText = "SSH needs confirmation for \(tunnelName)."
            alert.informativeText = text
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
        case .notice(let text):
            alert.messageText = "SSH is waiting for \(tunnelName)."
            alert.informativeText = text.isEmpty ? "Confirm on your security key." : text
            alert.addButton(withTitle: "OK")
        case .input(let text):
            alert.messageText = "SSH needs input for \(tunnelName)."
            alert.informativeText = text + "\nChostty does not save this answer."
            alert.accessoryView = field
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
        }
    }

    /// Shows a sheet on `window`, or an app-modal alert when there is none.
    func present(on window: NSWindow?) {
        if case .input = prompt { alert.window.initialFirstResponder = field }
        guard let window else {
            // A run-loop block, not a main-queue block, so main-queue work such
            // as `cancel()` still runs while the alert is modal.
            RunLoop.main.perform { [self] in
                MainActor.assumeIsolated {
                    guard completion != nil else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    answer(alert.runModal())
                }
            }
            return
        }
        parent = window
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.answer(response)
        }
    }

    /// Dismisses the prompt without an answer.
    func cancel() {
        finish(nil)
        if let parent, parent.sheets.contains(alert.window) {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else if NSApp.modalWindow === alert.window {
            NSApp.abortModal()
        }
    }

    private func answer(_ response: NSApplication.ModalResponse) {
        let accepted = response == .alertFirstButtonReturn
        switch prompt {
        case .hostKey:
            finish(Self.buffer(trust?.reply(trusted: accepted) ?? "no"))
        case .confirmation:
            finish(accepted ? Self.buffer("yes") : nil)
        case .notice:
            finish(nil)
        case .input:
            let value = field.stringValue
            field.stringValue = ""
            finish(accepted && !value.isEmpty ? Self.buffer(value) : nil)
        }
    }

    private func finish(_ reply: SSHSecretBuffer?) {
        field.stringValue = ""
        guard let completion else { return }
        self.completion = nil
        completion(reply)
    }

    private static func trustText(_ trust: SSHHostTrustSheetModel?) -> String {
        var lines = ["Destination: \(trust?.destination ?? "unknown")"]
        if let host = trust?.promptHost { lines.append("SSH is asking about: \(host)") }
        lines.append("Fingerprint: \(trust?.fingerprint ?? "not shown by SSH")")
        if let warning = trust?.warning { lines.append(warning) }
        lines.append("Trusting adds this key to known_hosts.")
        if let question = trust?.question { lines += ["", "SSH asked:", question] }
        return lines.joined(separator: "\n")
    }

    private static func buffer(_ value: String) -> SSHSecretBuffer {
        var bytes = Array(value.utf8)
        defer {
            bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = memset_s(base, buffer.count, 0, buffer.count)
            }
        }
        return bytes.withUnsafeBytes { SSHSecretBuffer(copying: $0) }
    }
}
