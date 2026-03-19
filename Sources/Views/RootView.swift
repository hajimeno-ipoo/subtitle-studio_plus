import SwiftUI

struct RootView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openSettings) private var openSettings

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
            case .info:
                Alert(
                    title: Text(state.title),
                    message: Text(state.message),
                    dismissButton: .default(Text("OK")) {
                        viewModel.dialogState = nil
                    }
                )
            case .success:
                Alert(
                    title: Text(state.title),
                    message: Text(state.message),
                    dismissButton: .default(Text("Done")) {
                        viewModel.dialogState = nil
                    }
                )
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
        .onChange(of: viewModel.isSettingsPresented) {
            guard viewModel.isSettingsPresented else { return }
            openSettings()
            viewModel.isSettingsPresented = false
        }
        .onAppear {
            AppDelegate.shared?.adjustMainWindowFrame(resolveSessionActive: viewModel.isResolveSessionActive)
        }
        .onChange(of: viewModel.isResolveSessionActive) {
            AppDelegate.shared?.adjustMainWindowFrame(resolveSessionActive: viewModel.isResolveSessionActive)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 24) {
            if viewModel.isResolveSessionActive {
                ResolveSessionBanner()
            }

            if viewModel.audioAsset == nil && viewModel.subtitles.isEmpty {
                UploadDropZone()
            } else {
                VStack(spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        LivePreviewPanel()
                        SubtitleListPanel()
                            .frame(width: 520)
                    }
                    WaveformTimelineView()
                        .frame(height: 320)
                }
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

private struct ResolveSessionBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.brandViolet)

            VStack(alignment: .leading, spacing: 4) {
                Text("Resolve session is active")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("Use EXPORT .SRT for a normal file, or EXPORT FOR DAVINCI to place Text+ subtitles on the current Resolve timeline.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.black, lineWidth: 2))
        .studioOffsetShadow(cornerRadius: 18, x: 4, y: 4)
    }
}
