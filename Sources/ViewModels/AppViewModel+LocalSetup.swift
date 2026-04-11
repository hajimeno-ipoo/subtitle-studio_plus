import AppKit
import Foundation

@MainActor
extension AppViewModel {
    func refreshLocalPipelineSetupStatus() async {
        await settings.loadIfNeeded()
        localPipelineSetupStatus = .checking
        localPipelineSetupStatus = await localPipelineSetupService.inspect(settings: settings.localPipelineSettings)
    }

    func downloadSelectedWhisperModel() async {
        guard !isLocalPipelineSetupBusy else { return }
        isLocalPipelineSetupBusy = true
        localPipelineSetupStatus.overall = .inProgress("Whisper モデルをダウンロードしています...")
        localPipelineSetupStatus.whisperModel.state = .inProgress("モデルをダウンロードしています...")
        defer { isLocalPipelineSetupBusy = false }

        do {
            let modelURL = try await localPipelineSetupService.downloadWhisperModel(for: settings.localPipelineSettings.baseModel)
            settings.localPipelineSettings.whisperModelPath = modelURL.path
            await refreshLocalPipelineSetupStatus()
        } catch {
            localPipelineSetupStatus.whisperModel.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            localPipelineSetupStatus.overall = .failed("モデルの準備に失敗しました。")
            present(error)
        }
    }

    func downloadSelectedCoreMLModel() async {
        guard !isLocalPipelineSetupBusy else { return }
        isLocalPipelineSetupBusy = true
        localPipelineSetupStatus.overall = .inProgress("Core ML モデルをダウンロードしています...")
        localPipelineSetupStatus.coreML.state = .inProgress("Core ML モデルをダウンロードしています...")
        defer { isLocalPipelineSetupBusy = false }

        do {
            let coreMLURL = try await localPipelineSetupService.downloadCoreMLModel(for: settings.localPipelineSettings.baseModel)
            settings.localPipelineSettings.whisperCoreMLModelPath = coreMLURL.path
            await refreshLocalPipelineSetupStatus()
        } catch {
            localPipelineSetupStatus.coreML.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            localPipelineSetupStatus.overall = .failed("Core ML モデルの準備に失敗しました。")
            present(error)
        }
    }

    func installLocalAlignmentTools() async {
        guard !isLocalPipelineSetupBusy else { return }
        isLocalPipelineSetupBusy = true
        localPipelineSetupStatus.overall = .inProgress("時間合わせの依存をセットアップしています...")
        localPipelineSetupStatus.aeneas.state = .inProgress("Python 環境を準備しています...")
        defer { isLocalPipelineSetupBusy = false }

        do {
            let pythonURL = try await localPipelineSetupService.installAlignmentTools(settings: settings.localPipelineSettings)
            settings.localPipelineSettings.aeneasPythonPath = pythonURL.path
            await refreshLocalPipelineSetupStatus()
        } catch {
            localPipelineSetupStatus.aeneas.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            localPipelineSetupStatus.overall = .failed("時間合わせの準備に失敗しました。")
            present(error)
        }
    }

    func handleLocalPipelineSetupAction(_ action: LocalPipelineSetupAction) async {
        switch action {
        case .downloadWhisperModel:
            await downloadSelectedWhisperModel()
        case .downloadCoreMLModel:
            await downloadSelectedCoreMLModel()
        case .installAlignmentTools:
            await installLocalAlignmentTools()
        case .openPythonGuide:
            openExternalGuide(urlString: "https://www.python.org/downloads/macos/")
        case .openFFmpegGuide:
            openExternalGuide(urlString: "https://brew.sh/")
        }
    }

    private func openExternalGuide(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
