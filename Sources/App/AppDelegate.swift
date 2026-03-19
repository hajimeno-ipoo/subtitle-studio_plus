import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private let preferredWindowSize = NSSize(width: 1440, height: 960)
    private let minimumWindowSize = NSSize(width: 1280, height: 820)
    private let resolveSessionExtraHeight: CGFloat = 104

    weak var viewModel: AppViewModel?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let intent = ResolveLaunchIntent.from(arguments: ProcessInfo.processInfo.arguments) {
            AppSession.shared.pendingResolveIntent = intent
        }
        Task { @MainActor in
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            adjustMainWindowFrame(resolveSessionActive: false)
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

    @MainActor
    func adjustMainWindowFrame(resolveSessionActive: Bool) {
        guard let window = NSApp.windows.first else { return }

        window.title = "SubtitleStudioPlus"
        window.minSize = minimumWindowSize

        let preferredHeight = preferredWindowSize.height + (resolveSessionActive ? resolveSessionExtraHeight : 0)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: preferredWindowSize)
        let fittedWidth = min(preferredWindowSize.width, visibleFrame.width)
        let fittedHeight = min(preferredHeight, visibleFrame.height)
        let targetWidth = max(minimumWindowSize.width, fittedWidth)
        let targetHeight = max(minimumWindowSize.height, fittedHeight)

        let originX = visibleFrame.origin.x + max((visibleFrame.width - targetWidth) / 2, 0)
        let originY = visibleFrame.origin.y + max((visibleFrame.height - targetHeight) / 2, 0)
        let targetFrame = NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight)

        window.setFrame(targetFrame, display: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppSession {
    static let shared = AppSession()
    var viewModel: AppViewModel?
    var pendingResolveIntent: ResolveLaunchIntent?
}
