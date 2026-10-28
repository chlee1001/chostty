import Foundation

enum SSHTunnelArguments {
    /// `interactive` tunnels prompt through the askpass broker: an unknown host
    /// key is asked about (`ask` overrides a user's `accept-new`), and ssh
    /// still refuses a changed one. Otherwise ssh never prompts at all.
    static func make(for definition: SSHTunnelDefinition, paths: SSHPaths, interactive: Bool = false) throws -> [String] {
        try definition.validate()

        var arguments = ["-N", "-n"]
        if !interactive { arguments += ["-o", "BatchMode=yes"] }
        arguments += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", interactive ? "StrictHostKeyChecking=ask" : "StrictHostKeyChecking=yes",
            "-o", "ForkAfterAuthentication=no",
            "-o", "PermitLocalCommand=no",
        ]
        if case .managed = definition.host.source {
            arguments += ["-F", paths.managedHostsFile.path]
        }
        arguments += [flag(for: definition.kind), specification(for: definition), "--", definition.host.alias]
        return arguments
    }

    private static func flag(for kind: SSHTunnelDefinition.Kind) -> String {
        switch kind {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }

    private static func specification(for definition: SSHTunnelDefinition) -> String {
        let bind = "\(address(definition.bindAddress)):\(definition.bindPort)"
        switch definition.kind {
        case .local, .remote:
            return "\(bind):\(address(definition.targetHost!)):\(definition.targetPort!)"
        case .dynamic:
            return bind
        }
    }

    private static func address(_ value: String) -> String {
        value.contains(":") && !(value.hasPrefix("[") && value.hasSuffix("]")) ? "[\(value)]" : value
    }
}
