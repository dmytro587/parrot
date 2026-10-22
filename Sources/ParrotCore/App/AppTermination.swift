import AppKit
import Foundation

/// Tears down loaded models when Parrot exits so subprocesses (Phonon `fermion serve`)
/// do not keep running and holding memory.
@MainActor
final class AppTerminationCoordinator: NSObject, NSApplicationDelegate {
    private let switcher: ModelSwitcher

    init(switcher: ModelSwitcher) {
        self.switcher = switcher
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await switcher.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
