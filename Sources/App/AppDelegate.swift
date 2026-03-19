import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: AppViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let intent = ResolveLaunchIntent.from(arguments: ProcessInfo.processInfo.arguments) {
            AppSession.shared.pendingResolveIntent = intent
        }
        Task { @MainActor in
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.hasUnsavedChanges else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Unsaved subtitle changes"
        alert.informativeText = "Current subtitle edits will be lost. Do you want to quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@MainActor
final class AppSession {
    static let shared = AppSession()
    var viewModel: AppViewModel?
    var pendingResolveIntent: ResolveLaunchIntent?
}
