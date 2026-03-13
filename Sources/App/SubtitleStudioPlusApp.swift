import SwiftUI
import AppKit

@main
struct SubtitleStudioPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()

    init() {
        let size = NSSize(width: 1440, height: 960)
        NSWindow.allowsAutomaticWindowTabbing = false
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.setContentSize(size)
                window.minSize = NSSize(width: 1280, height: 820)
                window.title = "AI Subtitle Studio"
            }
        }
    }

    var body: some Scene {
        WindowGroup("AI Subtitle Studio") {
            RootView()
                .environment(viewModel)
                .onAppear {
                    AppSession.shared.viewModel = viewModel
                    appDelegate.viewModel = viewModel
                }
        }
        .commands {
            SubtitleStudioCommands(viewModel: viewModel)
        }

        Settings {
            SettingsView()
                .environment(viewModel)
                .frame(width: 520, height: 240)
        }
    }
}

struct SubtitleStudioCommands: Commands {
    @Bindable var viewModel: AppViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandGroup(after: .newItem) {
            Button("Open Audio…") {
                viewModel.requestOpenAudio()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Export SRT…") {
                viewModel.requestExport()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(viewModel.subtitles.isEmpty)
        }

        CommandMenu("Playback") {
            Button(viewModel.isPlaying ? "Pause" : "Play") {
                viewModel.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!viewModel.canTogglePlayback)
        }

        CommandMenu("Subtitles") {
            Button("Delete Selected Subtitle") {
                viewModel.deleteSelectedSubtitle()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!viewModel.canDeleteSelectedSubtitle)

            Divider()

            Button("Move Left") {
                viewModel.nudgeSelectedSubtitle(delta: -AppViewModel.nudgeStep)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!viewModel.canUseTimelineShortcuts)

            Button("Move Right") {
                viewModel.nudgeSelectedSubtitle(delta: AppViewModel.nudgeStep)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!viewModel.canUseTimelineShortcuts)

            Button("Trim Start Left") {
                viewModel.resizeSelectedSubtitleStart(delta: -AppViewModel.nudgeStep)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.shift])
            .disabled(!viewModel.canUseTimelineShortcuts)

            Button("Trim End Right") {
                viewModel.resizeSelectedSubtitleEnd(delta: AppViewModel.nudgeStep)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.shift])
            .disabled(!viewModel.canUseTimelineShortcuts)

            Divider()

            Button("Undo") {
                viewModel.undo()
            }
            .keyboardShortcut("z", modifiers: [.command])
            .disabled(!viewModel.canUndo)

            Button("Redo") {
                viewModel.redo()
            }
            .keyboardShortcut("Z", modifiers: [.command, .shift])
            .disabled(!viewModel.canRedo)
        }
    }
}
