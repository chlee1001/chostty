import Foundation

struct FilesPanelRootResolver: Sendable {
    struct Inputs: Sendable {
        var focusedPanePWD: String?
        var sessionPWD: String?
        var workspacePWD: String?
        var homeDirectory: String

        init(
            focusedPanePWD: String?,
            sessionPWD: String?,
            workspacePWD: String?,
            homeDirectory: String = NSHomeDirectory()
        ) {
            self.focusedPanePWD = focusedPanePWD
            self.sessionPWD = sessionPWD
            self.workspacePWD = workspacePWD
            self.homeDirectory = homeDirectory
        }
    }

    func resolve(_ inputs: Inputs) -> String {
        for candidate in [
            inputs.focusedPanePWD,
            inputs.sessionPWD,
            inputs.workspacePWD,
            inputs.homeDirectory,
        ] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }

        return URL(fileURLWithPath: inputs.homeDirectory).standardizedFileURL.path
    }
}
