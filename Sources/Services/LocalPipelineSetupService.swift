import Foundation

final class LocalPipelineSetupService: @unchecked Sendable {
    private let fileManager: FileManager
    private let runtimePathResolver: AppRuntimePathResolver
    private let processRunner: any ExternalProcessRunning
    private let session: URLSession

    init(
        fileManager: FileManager = .default,
        runtimePathResolver: AppRuntimePathResolver = AppRuntimePathResolver(),
        processRunner: any ExternalProcessRunning = ExternalProcessRunner(),
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.runtimePathResolver = runtimePathResolver
        self.processRunner = processRunner
        self.session = session
    }

    func inspect(settings: LocalPipelineSettings) async -> LocalPipelineSetupStatus {
        let whisperModel = inspectWhisperModel(settings: settings)
        let coreML = inspectCoreML(settings: settings)
        let supportFiles = inspectSupportFiles(settings: settings)
        let python = inspectPython(settings: settings)
        let ffmpeg = inspectRequiredExecutable(
            rawPath: "ffmpeg",
            missingMessage: "FFmpeg が見つかりません。",
            action: .openFFmpegGuide
        )
        let aeneas = await inspectAeneasStatus(settings: settings, python: python, ffmpeg: ffmpeg)
        let ffprobe = inspectInformationalExecutable(
            rawPath: "ffprobe",
            toolName: "ffprobe"
        )
        let espeak = inspectInformationalExecutable(
            rawPath: "espeak",
            toolName: "eSpeak"
        )

        let overall: LocalPipelineSetupState
        if whisperModel.state.isReady && supportFiles.state.isReady && python.state.isReady && ffmpeg.state.isReady && aeneas.state.isReady {
            overall = .ready("ローカル字幕の準備ができています。")
        } else if case .failed(let message) = supportFiles.state {
            overall = .failed(message)
        } else if !whisperModel.state.isReady {
            overall = .missing("まず Whisper モデルを入れてください。")
        } else if !python.state.isReady {
            overall = .missing("まず Python 3 を入れてください。")
        } else if !ffmpeg.state.isReady {
            overall = .missing("まず FFmpeg を入れてください。")
        } else if !aeneas.state.isReady {
            overall = .missing("次に aeneas をセットアップしてください。")
        } else {
            overall = .missing("足りない項目があります。下のボタンから準備できます。")
        }

        return LocalPipelineSetupStatus(
            overall: overall,
            whisperModel: whisperModel,
            python: python,
            ffmpeg: ffmpeg,
            aeneas: aeneas,
            coreML: coreML,
            ffprobe: ffprobe,
            espeak: espeak,
            supportFiles: supportFiles,
            note: "高速化用 Core ML モデルは任意です。必要なら詳細設定から手動で指定できます。"
        )
    }

    func downloadWhisperModel(for baseModel: LocalBaseModel) async throws -> URL {
        let asset = LocalPipelineManagedAsset(baseModel: baseModel)
        let modelsDirectoryURL = runtimePathResolver.managedModelsDirectoryURL()
        try fileManager.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        let destinationURL = modelsDirectoryURL.appendingPathComponent(asset.fileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let temporaryURL = destinationURL.appendingPathExtension("download")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }

        let (downloadedURL, response) = try await session.download(from: asset.downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw LocalPipelineSetupError.downloadFailed("モデルのダウンロードに失敗しました。しばらくしてからもう一度お試しください。")
        }

        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: downloadedURL, to: temporaryURL)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    func downloadCoreMLModel(for baseModel: LocalBaseModel) async throws -> URL {
        let modelsDirectoryURL = runtimePathResolver.managedModelsDirectoryURL()
        try fileManager.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        let targetDirectoryURL = modelsDirectoryURL.appendingPathComponent(coreMLDirectoryName(for: baseModel), isDirectory: true)
        if fileManager.fileExists(atPath: targetDirectoryURL.path) {
            return targetDirectoryURL
        }

        let archiveURL = modelsDirectoryURL.appendingPathComponent("\(coreMLDirectoryName(for: baseModel)).zip")
        if fileManager.fileExists(atPath: archiveURL.path) {
            try? fileManager.removeItem(at: archiveURL)
        }

        let (downloadedURL, response) = try await session.download(from: coreMLArchiveURL(for: baseModel))
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw LocalPipelineSetupError.downloadFailed("Core ML モデルのダウンロードに失敗しました。")
        }

        let extractionDirectoryURL = modelsDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        defer { try? fileManager.removeItem(at: extractionDirectoryURL) }

        try fileManager.moveItem(at: downloadedURL, to: archiveURL)
        let unzipResult = try await runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, extractionDirectoryURL.path],
            timeout: 180
        )
        try? fileManager.removeItem(at: archiveURL)
        guard unzipResult.exitCode == 0 else {
            throw LocalPipelineSetupError.commandFailed(stderrText(from: unzipResult.stderr, fallback: "Core ML モデルの展開に失敗しました。"))
        }

        guard let extractedDirectoryURL = findExtractedCoreMLDirectory(in: extractionDirectoryURL) else {
            throw LocalPipelineSetupError.downloadFailed("Core ML モデルの展開結果が見つかりませんでした。")
        }

        try? fileManager.removeItem(at: targetDirectoryURL)
        try fileManager.moveItem(at: extractedDirectoryURL, to: targetDirectoryURL)
        return targetDirectoryURL
    }

    func installAlignmentTools(settings: LocalPipelineSettings) async throws -> URL {
        guard executableURL(for: "ffmpeg") != nil else {
            throw LocalPipelineSetupError.setupPrerequisiteMissing(
                "先に FFmpeg を入れてください。設定画面の案内ボタンから手順をご確認いただけます。"
            )
        }

        guard let bootstrapPythonURL = bootstrapPythonURL(settings: settings) else {
            throw LocalPipelineSetupError.pythonNotFound
        }

        let environmentDirectoryURL = runtimePathResolver.managedAeneasEnvironmentURL()
        let environmentPythonURL = environmentDirectoryURL.appendingPathComponent("bin/python3")

        if !fileManager.fileExists(atPath: environmentPythonURL.path) {
            try fileManager.createDirectory(
                at: environmentDirectoryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let venvResult = try await runCommand(
                executableURL: bootstrapPythonURL,
                arguments: ["-m", "venv", environmentDirectoryURL.path],
                timeout: 180
            )
            guard venvResult.exitCode == 0 else {
                throw LocalPipelineSetupError.commandFailed(stderrText(from: venvResult.stderr, fallback: "Python 環境の作成に失敗しました。"))
            }
        }

        let ensurePipResult = try await runCommand(
            executableURL: environmentPythonURL,
            arguments: ["-m", "ensurepip", "--upgrade"],
            timeout: 180
        )
        guard ensurePipResult.exitCode == 0 else {
            throw LocalPipelineSetupError.commandFailed(stderrText(from: ensurePipResult.stderr, fallback: "pip の準備に失敗しました。"))
        }

        let upgradeResult = try await runCommand(
            executableURL: environmentPythonURL,
            arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel", "numpy"],
            timeout: 420
        )
        guard upgradeResult.exitCode == 0 else {
            throw LocalPipelineSetupError.commandFailed(stderrText(from: upgradeResult.stderr, fallback: "Python 依存の更新に失敗しました。"))
        }

        let aeneasResult = try await runCommand(
            executableURL: environmentPythonURL,
            arguments: ["-m", "pip", "install", "aeneas"],
            timeout: 600
        )
        guard aeneasResult.exitCode == 0 else {
            throw LocalPipelineSetupError.commandFailed(stderrText(from: aeneasResult.stderr, fallback: "aeneas のインストールに失敗しました。"))
        }

        let verifyResult = try await runCommand(
            executableURL: environmentPythonURL,
            arguments: ["-c", "import aeneas.tools.execute_task"],
            timeout: 60
        )
        guard verifyResult.exitCode == 0 else {
            throw LocalPipelineSetupError.commandFailed(stderrText(from: verifyResult.stderr, fallback: "aeneas の確認に失敗しました。"))
        }

        return environmentPythonURL
    }

    private func inspectWhisperModel(settings: LocalPipelineSettings) -> LocalPipelineSetupRowStatus {
        if let existingURL = resolveExistingFile(from: settings.whisperModelPath) {
            return LocalPipelineSetupRowStatus(
                state: .ready("\(existingURL.lastPathComponent) を利用できます。"),
                action: nil
            )
        }

        let candidates = runtimePathResolver.candidateWhisperModelURLs(for: settings.baseModel)
        if let managedURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return LocalPipelineSetupRowStatus(
                state: .ready("\(managedURL.lastPathComponent) を利用できます。"),
                action: nil
            )
        }

        let asset = LocalPipelineManagedAsset(baseModel: settings.baseModel)
        return LocalPipelineSetupRowStatus(
            state: .missing("\(asset.displayName) がまだ入っていません。"),
            action: .downloadWhisperModel
        )
    }

    private func inspectCoreML(settings: LocalPipelineSettings) -> LocalPipelineSetupRowStatus {
        let trimmed = settings.whisperCoreMLModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingURL = resolveExistingFile(from: trimmed) {
            return LocalPipelineSetupRowStatus(
                state: .ready("見つかりました: \(existingURL.path)"),
                action: nil
            )
        }

        if let whisperModelURL = resolveExistingFile(from: settings.whisperModelPath) ?? runtimePathResolver.candidateWhisperModelURLs(for: settings.baseModel).first(where: { fileManager.fileExists(atPath: $0.path) }) {
            let expected = whisperModelURL.deletingPathExtension().appendingPathExtension("mlmodelc")
            let legacy = whisperModelURL
                .deletingPathExtension()
                .deletingLastPathComponent()
                .appendingPathComponent(whisperModelURL.deletingPathExtension().lastPathComponent + "-encoder.mlmodelc", isDirectory: true)
            if fileManager.fileExists(atPath: expected.path) {
                return LocalPipelineSetupRowStatus(state: .ready("見つかりました: \(expected.path)"), action: nil)
            }
            if fileManager.fileExists(atPath: legacy.path) {
                return LocalPipelineSetupRowStatus(state: .ready("見つかりました: \(legacy.path)"), action: nil)
            }
        }

        return LocalPipelineSetupRowStatus(
            state: .missing("未設定です。なくても使えますが、あると速くなります。"),
            action: .downloadCoreMLModel
        )
    }

    private func inspectSupportFiles(settings: LocalPipelineSettings) -> LocalPipelineSetupRowStatus {
        let scriptURL = resolveExistingFile(from: settings.aeneasScriptPath)
        let dictionaryURL = resolveExistingFile(from: settings.correctionDictionaryPath)

        guard scriptURL != nil, dictionaryURL != nil else {
            return LocalPipelineSetupRowStatus(
                state: .failed("同梱済みの補助ファイルが見つかりません。アプリの再配置をご確認ください。"),
                action: nil
            )
        }

        return LocalPipelineSetupRowStatus(
            state: .ready("時間合わせスクリプトと補正辞書はアプリ内に入っています。"),
            action: nil
        )
    }

    private func inspectPython(settings: LocalPipelineSettings) -> LocalPipelineSetupRowStatus {
        let pythonURL = executableURL(for: settings.aeneasPythonPath)
            ?? executableURL(for: "python3")
            ?? executableURL(for: "python")

        if let pythonURL {
            return LocalPipelineSetupRowStatus(
                state: .ready("見つかりました: \(pythonURL.path)"),
                action: nil
            )
        }

        return LocalPipelineSetupRowStatus(
            state: .missing("Python 3 が見つかりません。"),
            action: .openPythonGuide
        )
    }

    private func bootstrapPythonURL(settings: LocalPipelineSettings) -> URL? {
        let preferredCandidates = [
            executableURL(for: settings.aeneasPythonPath),
            executableURL(for: "python3"),
            executableURL(for: "python")
        ]
        return preferredCandidates.compactMap { $0 }.first
    }

    private func executableURL(for rawPath: String) -> URL? {
        runtimePathResolver
            .candidateExecutableURLs(for: rawPath)
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func coreMLArchiveURL(for baseModel: LocalBaseModel) -> URL {
        switch baseModel {
        case .kotobaWhisperV2, .kotobaWhisperBilingual:
            return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-encoder.mlmodelc.zip?download=true")!
        }
    }

    private func coreMLDirectoryName(for baseModel: LocalBaseModel) -> String {
        switch baseModel {
        case .kotobaWhisperV2:
            return "ggml-kotoba-whisper-v2.0-encoder.mlmodelc"
        case .kotobaWhisperBilingual:
            return "ggml-kotoba-whisper-bilingual-v1.0-encoder.mlmodelc"
        }
    }

    private func findExtractedCoreMLDirectory(in directoryURL: URL) -> URL? {
        if let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "mlmodelc" {
                    return fileURL
                }
            }
        }
        return nil
    }

    private func inspectRequiredExecutable(
        rawPath: String,
        missingMessage: String,
        action: LocalPipelineSetupAction
    ) -> LocalPipelineSetupRowStatus {
        if let executableURL = executableURL(for: rawPath) {
            return LocalPipelineSetupRowStatus(
                state: .ready("見つかりました: \(executableURL.path)"),
                action: nil
            )
        }

        return LocalPipelineSetupRowStatus(
            state: .missing(missingMessage),
            action: action
        )
    }

    private func inspectInformationalExecutable(
        rawPath: String,
        toolName: String
    ) -> LocalPipelineSetupRowStatus {
        if let executableURL = executableURL(for: rawPath) {
            return LocalPipelineSetupRowStatus(
                state: .ready("見つかりました: \(executableURL.path)"),
                action: nil
            )
        }

        return LocalPipelineSetupRowStatus(
            state: .ready("\(toolName) は現在のアプリでは必須ではありません。"),
            action: nil
        )
    }

    private func inspectAeneasStatus(
        settings: LocalPipelineSettings,
        python: LocalPipelineSetupRowStatus,
        ffmpeg: LocalPipelineSetupRowStatus
    ) async -> LocalPipelineSetupRowStatus {
        guard let pythonURL = executableURL(for: settings.aeneasPythonPath)
            ?? executableURL(for: "python3")
            ?? executableURL(for: "python") else {
            return LocalPipelineSetupRowStatus(
                state: .missing("Python が無いため確認できません。"),
                action: .openPythonGuide
            )
        }
        guard python.state.isReady else {
            return LocalPipelineSetupRowStatus(
                state: .missing("Python が無いため確認できません。"),
                action: .openPythonGuide
            )
        }
        guard ffmpeg.state.isReady else {
            return LocalPipelineSetupRowStatus(
                state: .missing("先に FFmpeg を入れる必要があります。"),
                action: .openFFmpegGuide
            )
        }

        do {
            let result = try await runCommand(
                executableURL: pythonURL,
                arguments: ["-c", "import aeneas.tools.execute_task"],
                timeout: 30
            )
            if result.exitCode == 0 {
                return LocalPipelineSetupRowStatus(
                    state: .ready("aeneas が使えます。"),
                    action: nil
                )
            }

            return LocalPipelineSetupRowStatus(
                state: .missing("aeneas がまだ入っていません。"),
                action: .installAlignmentTools
            )
        } catch {
            return LocalPipelineSetupRowStatus(
                state: .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription),
                action: .installAlignmentTools
            )
        }
    }

    private func resolveExistingFile(from rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return runtimePathResolver
            .candidateURLs(forResourcePath: trimmed)
            .first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private func runCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ExternalProcessResult {
        try await processRunner.run(
            ExternalProcessRequest(
                executablePath: executableURL.path,
                arguments: arguments,
                workingDirectory: nil,
                environment: [:],
                timeout: timeout
            )
        )
    }

    private func stderrText(from data: Data, fallback: String) -> String {
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : fallback
    }
}
