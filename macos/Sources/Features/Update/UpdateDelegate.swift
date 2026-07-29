import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Chostty is a fork with its own product identity (Chostty.app /
        // chostty / com.chostty.app). Pointing at upstream Ghostty's appcast
        // would let an upstream release replace this fork, so in-app updates
        // stay fully disabled until Chostty owns a feed, signing key, hosting,
        // and rotation policy.
        //
        // Returning nil means Sparkle has no feed and cannot find, download,
        // or install anything.
        return nil
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }
}
