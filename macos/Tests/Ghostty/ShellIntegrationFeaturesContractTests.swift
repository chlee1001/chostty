import Foundation
import Testing
@testable import Ghostty
@testable import GhosttyKit

struct ShellIntegrationFeaturesContractTests {
    @Test("Swift packed-struct scanning matches libghostty")
    func scannedBitsMatchLibghostty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chostty-shell-features-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixtures = [
            "",
            "shell-integration-features = no-cursor\n",
            "shell-integration-features = ssh-env\n",
            "shell-integration-features = no-ssh-env\n",
            "shell-integration-features = false\n",
            "shell-integration-features = ssh-terminfo\n",
            "shell-integration-features = unknown,ssh-env\n",
            "shell-integration-features = no-ssh-env\nconfig-file = included\n",
        ]

        for (index, text) in fixtures.enumerated() {
            let root = directory.appendingPathComponent("config-\(index)")
            try text.write(to: root, atomically: true, encoding: .utf8)
            if index == fixtures.count - 1 {
                try "shell-integration-features = ssh-env\n".write(
                    to: directory.appendingPathComponent("included"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let provenance = SSHTerminalEnvironmentPolicy.collect(
                configPath: root,
                environment: [:],
                arguments: ["Ghostty"],
                isRunningInXcode: false,
                themeDirectories: []
            )
            guard let config = ghostty_config_new() else {
                Issue.record("ghostty_config_new failed")
                return
            }
            defer { ghostty_config_free(config) }
            ghostty_config_load_file(config, root.path)
            ghostty_config_load_recursive_files(config)
            ghostty_config_finalize(config)

            var value: CUnsignedInt = 0
            let key = "shell-integration-features"
            #expect(ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))))
            #expect(provenance.scanned.rawValue == value)
        }
    }
}
