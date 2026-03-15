import SwiftUI

struct RootView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            content
                .padding(24)
                .background(Color.backgroundYellow)
        }
        .frame(minWidth: 1280, minHeight: 820)
        .background(Color.backgroundYellow)
        .fileImporter(
            isPresented: bind(\.isFileImporterPresented),
            allowedContentTypes: AudioFileSupport.supportedContentTypes(),
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await viewModel.handleImportedURL(url) }
            }
        }
        .fileExporter(
            isPresented: bind(\.isFileExporterPresented),
            document: viewModel.exportDocument(),
            contentType: .subtitleStudioSRT,
            defaultFilename: (viewModel.audioAsset?.fileName as NSString?)?.deletingPathExtension ?? "subtitles"
        ) { result in
            viewModel.handleExportCompletion(result)
        }
        .alert(item: bind(\.dialogState)) { state in
            switch state.kind {
            case .error:
                Alert(
                    title: Text(state.title),
                    message: Text(state.message),
                    dismissButton: .default(Text("OK")) {
                        viewModel.dialogState = nil
                    }
                )
            case .unsavedChanges:
                Alert(
                    title: Text(state.title),
                    message: Text(state.message),
                    primaryButton: .destructive(Text("Replace")) {
                        Task { await viewModel.confirmPendingImport() }
                    },
                    secondaryButton: .cancel {
                        viewModel.cancelPendingImport()
                    }
                )
            case .confirmReset:
                Alert(
                    title: Text(state.title),
                    message: Text(state.message),
                    primaryButton: .destructive(Text("Return to Start")) {
                        viewModel.resetProject()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .sheet(isPresented: bind(\.isSettingsPresented)) {
            SettingsView()
                .environment(viewModel)
                .padding(24)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.audioAsset == nil {
            UploadDropZone()
        } else {
            VStack(spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    LivePreviewPanel()
                    SubtitleListPanel()
                        .frame(width: 480)
                }
                WaveformTimelineView()
                    .frame(height: 320)
            }
        }
    }

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppViewModel, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { viewModel[keyPath: keyPath] = $0 }
        )
    }
}
