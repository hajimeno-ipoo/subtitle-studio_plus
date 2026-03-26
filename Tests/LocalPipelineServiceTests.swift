@testable import SubtitleStudioPlus
import Foundation
import Testing

actor MockLocalPipelineAnalyzing: LocalPipelineAnalyzing {
    private var callCount = 0
    private var lastFileURL: URL?
    private var lastSettings: LocalPipelineSettings?
    let result: LocalPipelineResult

    init(result: LocalPipelineResult) {
        self.result = result
    }

    func analyze(
        fileURL: URL,
        settings: LocalPipelineSettings,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> LocalPipelineResult {
        callCount += 1
        lastFileURL = fileURL
        lastSettings = settings
        return result
    }

    func snapshot() -> (callCount: Int, lastFileURL: URL?, lastSettings: LocalPipelineSettings?) {
        (callCount, lastFileURL, lastSettings)
    }
}

actor MockExternalProcessRunner: ExternalProcessRunning {
    enum AlignmentMode {
        case success
        case partialFallback
        case emptyResult
    }

    enum WhisperMode {
        case success
        case empty
    }

    private(set) var requests: [ExternalProcessRequest] = []
    private let alignmentMode: AlignmentMode
    private let whisperMode: WhisperMode

    init(
        alignmentMode: AlignmentMode = .success,
        whisperMode: WhisperMode = .success
    ) {
        self.alignmentMode = alignmentMode
        self.whisperMode = whisperMode
    }

    func run(_ request: ExternalProcessRequest) async throws -> ExternalProcessResult {
        requests.append(request)
        if request.arguments.contains("--segments-json") {
            return try await runAeneas(request)
        }
        return try runWhisper(request)
    }

    func snapshot() -> [ExternalProcessRequest] {
        requests
    }

    private func runWhisper(_ request: ExternalProcessRequest) throws -> ExternalProcessResult {
        let outputPrefix = try requireValue("-of", in: request.arguments)
        let outputURL = URL(fileURLWithPath: outputPrefix).appendingPathExtension("json")
        let payload: String
        switch whisperMode {
        case .success:
            payload = """
            {
              "segments": [
                {
                  "start": 0.0,
                  "end": 1.6,
                  "text": "愛してる",
                  "confidence": 0.92
                },
                {
                  "start": 1.7,
                  "end": 3.4,
                  "text": "君のこと",
                  "confidence": 0.88
                }
              ]
            }
            """
        case .empty:
            payload = """
            {
              "segments": [
                {
                  "start": 0.0,
                  "end": 1.6,
                  "text": "",
                  "confidence": 0.92
                }
              ]
            }
            """
        }
        try Data(payload.utf8).write(to: outputURL, options: [.atomic])
        return ExternalProcessResult(stdout: Data(), stderr: Data("ok\n".utf8), exitCode: 0)
    }

    private func runAeneas(_ request: ExternalProcessRequest) async throws -> ExternalProcessResult {
        let segmentsURL = URL(fileURLWithPath: try requireValue("--segments-json", in: request.arguments))
        let outputURL = URL(fileURLWithPath: try requireValue("--output-json", in: request.arguments))
        let manifestData = try Data(contentsOf: segmentsURL)
        let manifest = try JSONDecoder().decode(AlignmentManifestFixture.self, from: manifestData)

        if let callback = request.onStderrChunk {
            for (index, segment) in manifest.segments.enumerated() {
                let line = "Aligning block \(index + 1)/\(max(manifest.segments.count, 1)): \(segment.segmentId)\n"
                await callback(Data(line.utf8))
            }
        }

        let alignedSegments: [AlignedSegmentFixture]
        switch alignmentMode {
        case .success:
            alignedSegments = manifest.segments.map { segment in
                AlignedSegmentFixture(
                    segmentId: segment.segmentId,
                    start: segment.startTime + 0.05,
                    end: max(segment.endTime, segment.startTime + 1.0),
                    text: segment.text
                )
            }
        case .partialFallback:
            alignedSegments = manifest.segments.enumerated().compactMap { index, segment in
                guard index == 0 else { return nil }
                return AlignedSegmentFixture(
                    segmentId: segment.segmentId,
                    start: segment.startTime + 0.05,
                    end: max(segment.endTime, segment.startTime + 1.0),
                    text: segment.text
                )
            }
        case .emptyResult:
            alignedSegments = []
        }

        let payload = AlignmentOutputFixture(
            runId: manifest.runId,
            engineType: "localPipeline",
            modelName: "aeneas",
            segments: alignedSegments
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: outputURL, options: [.atomic])
        return ExternalProcessResult(stdout: data, stderr: Data("aligned\n".utf8), exitCode: 0)
    }

    private func requireValue(_ flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            throw TestError.missingArgument(flag)
        }
        return arguments[index + 1]
    }
}

private enum TestError: Error {
    case missingArgument(String)
}

private struct AlignmentManifestFixture: Decodable {
    struct Segment: Decodable {
        var segmentId: String
        var startTime: Double
        var endTime: Double
        var text: String
    }

    var runId: String
    var sourceFileName: String
    var language: String
    var segments: [Segment]
}

private struct AlignmentOutputFixture: Codable {
    var runId: String
    var engineType: String
    var modelName: String
    var segments: [AlignedSegmentFixture]
}

private struct AlignedSegmentFixture: Codable {
    var segmentId: String
    var start: Double
    var end: Double
    var text: String
}

struct LocalPipelineServiceTests {
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
    }

    @Test
    func definesLocalPipelineServiceAndAnalyzeEntry() {
        let service = LocalPipelineService()
        let analyzing: any LocalPipelineAnalyzing = service

        #expect(analyzing as? LocalPipelineService != nil)
    }

    @Test
    func includesMandatoryPipelineStagesInOrder() {
        let stages = RunManifestStage.allCases
        let requiredStages: [RunManifestStage] = [
            .normalized,
            .chunked,
            .baseTranscribed,
            .aligned,
            .corrected,
            .outputsWritten
        ]

        let indices = requiredStages.compactMap { stages.firstIndex(of: $0) }
        #expect(indices.count == requiredStages.count)
        #expect(indices == indices.sorted())
    }

    @MainActor
    @Test
    func appViewModelKeepsGeminiPathAndAddsLocalPipelineBranch() async throws {
        let result = LocalPipelineResult(
            subtitles: [SubtitleItem(startTime: 0.0, endTime: 1.0, text: "hello")],
            runDirectoryURL: URL(fileURLWithPath: "/tmp/run-1"),
            finalSRTURL: URL(fileURLWithPath: "/tmp/run-1/final/final.srt")
        )
        let mock = MockLocalPipelineAnalyzing(result: result)
        let viewModel = AppViewModel(localPipelineService: mock)

        let userDefaults = UserDefaults(suiteName: "LocalPipelineServiceTests.\(UUID().uuidString)")!
        viewModel.settings = SettingsStore(
            loadKeychain: { "" },
            saveKeychain: { _ in },
            userDefaults: userDefaults
        )
        await viewModel.settings.loadIfNeeded()
        viewModel.settings.selectedSRTGenerationEngine = .localPipeline
        viewModel.audioAsset = AudioAsset(
            url: makeTempFileURL(),
            fileName: "input.wav",
            duration: 1,
            fileSize: 1,
            contentType: nil
        )

        await viewModel.analyzeAudio()

        let snapshot = await mock.snapshot()
        #expect(snapshot.callCount == 1)
        #expect(snapshot.lastFileURL == viewModel.audioAsset?.url)
        #expect(snapshot.lastSettings == viewModel.settings.localPipelineSettings)
        #expect(viewModel.status == .completed)
        #expect(viewModel.subtitles == result.subtitles)
        #expect(viewModel.lastLocalPipelineRunDirectoryURL == result.runDirectoryURL)
        #expect(viewModel.lastLocalPipelineResult?.finalSRTURL == result.finalSRTURL)
    }

    @Test
    func runtimePathResolverSearchesProjectResourcesAndPathExecutables() throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRootURL = sandboxURL.appendingPathComponent("ProjectRoot", isDirectory: true)
        let toolsURL = projectRootURL.appendingPathComponent("Tools/aeneas", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let scriptURL = toolsURL.appendingPathComponent("align_subtitles.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: scriptURL)

        let resolver = AppRuntimePathResolver(
            fileManager: .default,
            environment: ["PATH": "/custom/bin:/usr/local/bin"],
            projectRootOverride: projectRootURL,
            appSupportBaseOverride: sandboxURL.appendingPathComponent("AppSupport", isDirectory: true)
        )

        let resourceCandidates = resolver.candidateURLs(forResourcePath: "Tools/aeneas/align_subtitles.py")
        #expect(resourceCandidates.contains(scriptURL))

        let executableCandidates = resolver.candidateExecutableURLs(for: "python3")
        #expect(executableCandidates.contains(sandboxURL.appendingPathComponent("AppSupport/aeneas-venv/bin/python3")))
        #expect(executableCandidates.contains(URL(fileURLWithPath: "/custom/bin/python3")))
        #expect(executableCandidates.contains(URL(fileURLWithPath: "/opt/homebrew/bin/python3")))
    }

    @Test
    func localPipelineServiceMatchesWhisperAndAeneasContract() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

        let whisperCLIURL = sandboxURL.appendingPathComponent("whisper-cli")
        try writeExecutablePlaceholder(to: whisperCLIURL)

        let pythonURL = sandboxURL.appendingPathComponent("python3")
        try writeExecutablePlaceholder(to: pythonURL)

        let whisperModelURL = sandboxURL.appendingPathComponent("ggml-base.bin")
        try Data("model".utf8).write(to: whisperModelURL)

        let coreMLURL = sandboxURL.appendingPathComponent("custom-coreml.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: coreMLURL, withIntermediateDirectories: true)

        let aeneasScriptURL = sandboxURL.appendingPathComponent("align_subtitles.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: aeneasScriptURL)

        let dictionaryURL = sandboxURL.appendingPathComponent("dictionary.json")
        try Data(
            """
            {
              "version": "1",
              "language": "ja",
              "description": "test",
              "rules": [{ "type": "exact", "from": "愛してる", "to": "愛してる" }]
            }
            """.utf8
        ).write(to: dictionaryURL)

        let knownLyricsURL = sandboxURL.appendingPathComponent("known_lyrics.txt")
        try Data("愛してる\n君のこと\n".utf8).write(to: knownLyricsURL)

        var settings = LocalPipelineSettings.productionDefault
        settings.language = "ja"
        settings.initialPrompt = "曲名 夕焼け"
        settings.whisperCLIPath = whisperCLIURL.path
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.whisperCoreMLModelPath = coreMLURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.knownLyricsPath = knownLyricsURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner()
        let service = LocalPipelineService(processRunner: runner)

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            progress: { _ in }
        )

        let requests = await runner.snapshot()
        #expect(requests.count == 2)

        let whisperRequest = try #require(requests.first)
        let promptIndex = try #require(whisperRequest.arguments.firstIndex(of: "--prompt"))
        let prompt = whisperRequest.arguments[promptIndex + 1]
        let expectedBasePrompt = """
        日本語の歌詞です。
        自然な区切りの日本語の歌詞として認識してください。
        歌詞らしい語順と自然な表記を優先してください。
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(normalizedPrompt.hasPrefix(expectedBasePrompt))
        #expect(prompt.contains("曲名 夕焼け"))

        let aeneasRequest = try #require(requests.last)
        #expect(aeneasRequest.arguments.contains("--segments-json"))
        #expect(aeneasRequest.arguments.contains("--output-json"))

        #expect(FileManager.default.fileExists(atPath: result.finalSRTURL.path))
        #expect(result.subtitles.count == 2)
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
        #expect(!result.subtitles.allSatisfy { $0.startTime == 0 && $0.endTime == 0.1 })

        let runLog = try String(contentsOf: result.runDirectoryURL.appendingPathComponent("logs/run.jsonl"), encoding: .utf8)
        #expect(runLog.contains("\"stage\":\"baseTranscribing\""))
        #expect(runLog.contains("\"stage\":\"aligning\""))
        #expect(runLog.contains("\"stage\":\"writingOutputs\""))
    }

    @Test
    func localPipelineFallsBackToWhisperTimingWhenOnlySomeBlocksMissAlignment() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

        let whisperCLIURL = sandboxURL.appendingPathComponent("whisper-cli")
        try writeExecutablePlaceholder(to: whisperCLIURL)

        let pythonURL = sandboxURL.appendingPathComponent("python3")
        try writeExecutablePlaceholder(to: pythonURL)

        let whisperModelURL = sandboxURL.appendingPathComponent("ggml-base.bin")
        try Data("model".utf8).write(to: whisperModelURL)

        let aeneasScriptURL = sandboxURL.appendingPathComponent("align_subtitles.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: aeneasScriptURL)

        let dictionaryURL = sandboxURL.appendingPathComponent("dictionary.json")
        try Data(
            """
            {
              "version": "1",
              "language": "ja",
              "description": "test",
              "rules": []
            }
            """.utf8
        ).write(to: dictionaryURL)

        var settings = LocalPipelineSettings.productionDefault
        settings.whisperCLIPath = whisperCLIURL.path
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner(alignmentMode: .partialFallback)
        let service = LocalPipelineService(processRunner: runner)

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            progress: { _ in }
        )

        #expect(result.subtitles.count == 2)
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
        #expect(result.subtitles.first?.startTime == 0.05)
        #expect(result.subtitles.first?.endTime == 1.6)
        #expect(result.subtitles.last?.startTime == 1.7)
        #expect(result.subtitles.last?.endTime == 3.4)
    }

    @Test
    func localPipelineFailsWhenAeneasProducesNoAlignedBlocks() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

        let whisperCLIURL = sandboxURL.appendingPathComponent("whisper-cli")
        try writeExecutablePlaceholder(to: whisperCLIURL)

        let pythonURL = sandboxURL.appendingPathComponent("python3")
        try writeExecutablePlaceholder(to: pythonURL)

        let whisperModelURL = sandboxURL.appendingPathComponent("ggml-base.bin")
        try Data("model".utf8).write(to: whisperModelURL)

        let aeneasScriptURL = sandboxURL.appendingPathComponent("align_subtitles.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: aeneasScriptURL)

        let dictionaryURL = sandboxURL.appendingPathComponent("dictionary.json")
        try Data(
            """
            {
              "version": "1",
              "language": "ja",
              "description": "test",
              "rules": []
            }
            """.utf8
        ).write(to: dictionaryURL)

        var settings = LocalPipelineSettings.productionDefault
        settings.whisperCLIPath = whisperCLIURL.path
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner(alignmentMode: .emptyResult)
        let service = LocalPipelineService(processRunner: runner)

        await #expect(throws: LocalPipelineError.alignmentFailed("aeneas did not align any subtitle blocks.")) {
            try await service.analyze(
                fileURL: audioURL,
                settings: settings,
                progress: { _ in }
            )
        }
    }

    @Test
    func localPipelineFailsWhenWhisperReturnsNoUsableText() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

        let whisperCLIURL = sandboxURL.appendingPathComponent("whisper-cli")
        try writeExecutablePlaceholder(to: whisperCLIURL)

        let pythonURL = sandboxURL.appendingPathComponent("python3")
        try writeExecutablePlaceholder(to: pythonURL)

        let whisperModelURL = sandboxURL.appendingPathComponent("ggml-base.bin")
        try Data("model".utf8).write(to: whisperModelURL)

        let aeneasScriptURL = sandboxURL.appendingPathComponent("align_subtitles.py")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: aeneasScriptURL)

        let dictionaryURL = sandboxURL.appendingPathComponent("dictionary.json")
        try Data(
            """
            {
              "version": "1",
              "language": "ja",
              "description": "test",
              "rules": []
            }
            """.utf8
        ).write(to: dictionaryURL)

        var settings = LocalPipelineSettings.productionDefault
        settings.whisperCLIPath = whisperCLIURL.path
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner(whisperMode: .empty)
        let service = LocalPipelineService(processRunner: runner)

        await #expect(throws: LocalPipelineError.emptyTranscription("ローカル字幕を生成できませんでした。音声から歌詞を読み取れませんでした。")) {
            try await service.analyze(
                fileURL: audioURL,
                settings: settings,
                progress: { _ in }
            )
        }
    }
}

private func writeExecutablePlaceholder(to url: URL) throws {
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func writeTestWAV(to url: URL) throws {
    let sampleRate = 16_000
    let durationSeconds = 4.0
    let frameCount = Int(Double(sampleRate) * durationSeconds)
    var pcm = Data(capacity: frameCount * 2)
    for index in 0..<frameCount {
        let angle = (Double(index) / Double(sampleRate)) * 2 * Double.pi * 440
        let value = Int16((sin(angle) * 12_000).rounded()).littleEndian
        var mutable = value
        withUnsafeBytes(of: &mutable) { pcm.append(contentsOf: $0) }
    }

    let dataChunkSize = pcm.count
    let riffChunkSize = 36 + dataChunkSize

    var wav = Data()
    wav.append(Data("RIFF".utf8))
    wav.append(littleEndianBytes(UInt32(riffChunkSize)))
    wav.append(Data("WAVE".utf8))
    wav.append(Data("fmt ".utf8))
    wav.append(littleEndianBytes(UInt32(16)))
    wav.append(littleEndianBytes(UInt16(1)))
    wav.append(littleEndianBytes(UInt16(1)))
    wav.append(littleEndianBytes(UInt32(sampleRate)))
    wav.append(littleEndianBytes(UInt32(sampleRate * 2)))
    wav.append(littleEndianBytes(UInt16(2)))
    wav.append(littleEndianBytes(UInt16(16)))
    wav.append(Data("data".utf8))
    wav.append(littleEndianBytes(UInt32(dataChunkSize)))
    wav.append(pcm)

    try wav.write(to: url, options: [.atomic])
}

private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
}
