import SwiftUI
import AppKit

@main
struct SubtitleStudioPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup("SubtitleStudioPlus") {
            RootView()
                .environment(viewModel)
                .onAppear {
                    AppSession.shared.viewModel = viewModel
                    appDelegate.viewModel = viewModel
                    viewModel.startResolveBridgeMonitoring()
                    if let intent = AppSession.shared.pendingResolveIntent {
                        AppSession.shared.pendingResolveIntent = nil
                        Task { await viewModel.handleResolveLaunch(intent) }
                    }
                }
        }
        .commands {
            SubtitleStudioCommands(viewModel: viewModel)
        }

        Settings {
            SettingsView()
                .environment(viewModel)
                .frame(minWidth: 760, minHeight: 520)
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
                viewModel.requestStandardExport()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!viewModel.canExportStandardSRT)

            if viewModel.isResolveSessionActive {
                Button("Export for DaVinci") {
                    viewModel.requestDaVinciExport()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(!viewModel.canExportForDaVinci)
            }
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
