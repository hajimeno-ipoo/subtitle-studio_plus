@testable import SubtitleStudioPlus
import Foundation
import Testing

actor MockLocalPipelineAnalyzing: LocalPipelineAnalyzing {
    private var callCount = 0
    private var lastFileURL: URL?
    private var lastSettings: LocalPipelineSettings?
    private var lastLyricsReference: LocalLyricsReferenceInput?
    let result: LocalPipelineResult

    init(result: LocalPipelineResult) {
        self.result = result
    }

    func analyze(
        fileURL: URL,
        settings: LocalPipelineSettings,
        lyricsReference: LocalLyricsReferenceInput?,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> LocalPipelineResult {
        callCount += 1
        lastFileURL = fileURL
        lastSettings = settings
        lastLyricsReference = lyricsReference
        return result
    }

    func snapshot() -> (callCount: Int, lastFileURL: URL?, lastSettings: LocalPipelineSettings?, lastLyricsReference: LocalLyricsReferenceInput?) {
        (callCount, lastFileURL, lastSettings, lastLyricsReference)
    }
}

actor MockExternalProcessRunner: ExternalProcessRunning {
    enum AlignmentMode {
        case success
        case partialFallback
        case emptyResult
        case largeShift
        case clipEdgesForSingleLine
        case gappedGrouped
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
                  "end": 0.9,
                  "text": "愛してる",
                  "confidence": 0.92
                },
                {
                  "start": 1.1,
                  "end": 1.9,
                  "text": "君のこと",
                  "confidence": 0.88
                },
                {
                  "start": 3.2,
                  "end": 3.9,
                  "text": "離さない",
                  "confidence": 0.86
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
            alignedSegments = manifest.segments.flatMap { segment in
                makeAlignedFixtures(for: segment, startOffset: 0.05)
            }
        case .largeShift:
            alignedSegments = manifest.segments.flatMap { segment in
                makeAlignedFixtures(for: segment, startOffset: 1.2)
            }
        case .clipEdgesForSingleLine:
            alignedSegments = manifest.segments.flatMap { segment in
                if let ids = segment.lineSegmentIDs, let texts = segment.lineTexts, ids.count == texts.count, !ids.isEmpty {
                    return makeAlignedFixtures(for: segment, startOffset: 0.05)
                }
                return [
                    AlignedSegmentFixture(
                        segmentId: segment.segmentId,
                        start: segment.startTime - 1.2,
                        end: segment.endTime + 1.2,
                        text: segment.text
                    )
                ]
            }
        case .gappedGrouped:
            alignedSegments = manifest.segments.flatMap { segment in
                makeGappedGroupedFixtures(for: segment)
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

    private func makeAlignedFixtures(for segment: AlignmentManifestFixture.Segment, startOffset: Double) -> [AlignedSegmentFixture] {
        if let ids = segment.lineSegmentIDs, let texts = segment.lineTexts, ids.count == texts.count, !ids.isEmpty {
            let span = max(segment.endTime - segment.startTime, Double(ids.count))
            let slice = span / Double(ids.count)
            return zip(ids.indices, zip(ids, texts)).map { idx, pair in
                let (id, text) = pair
                let start = segment.startTime + (slice * Double(idx)) + startOffset
                let end = min(segment.endTime + startOffset, segment.startTime + (slice * Double(idx + 1)) + startOffset)
                return AlignedSegmentFixture(
                    segmentId: id,
                    start: start,
                    end: max(start + 0.35, end),
                    text: text
                )
            }
        }

        return [
            AlignedSegmentFixture(
                segmentId: segment.segmentId,
                start: segment.startTime + startOffset,
                end: max(segment.endTime + startOffset, segment.startTime + startOffset + 1.0),
                text: segment.text
            )
        ]
    }

    private func makeGappedGroupedFixtures(for segment: AlignmentManifestFixture.Segment) -> [AlignedSegmentFixture] {
        if let ids = segment.lineSegmentIDs,
           let texts = segment.lineTexts,
           let lineStarts = segment.lineStartTimes,
           let lineEnds = segment.lineEndTimes,
           ids.count == 2,
           texts.count == 2,
           lineStarts.count == 2,
           lineEnds.count == 2 {
            return [
                AlignedSegmentFixture(
                    segmentId: ids[0],
                    start: lineStarts[0],
                    end: max(lineStarts[0] + 0.35, lineEnds[0] - 0.6),
                    text: texts[0]
                ),
                AlignedSegmentFixture(
                    segmentId: ids[1],
                    start: lineStarts[1] + 0.6,
                    end: lineEnds[1],
                    text: texts[1]
                )
            ]
        }

        return makeAlignedFixtures(for: segment, startOffset: 0.05)
    }

}

private final class MockWhisperTranscriber: @unchecked Sendable, LocalWhisperTranscribing {
    enum Mode {
        case success
        case empty
    }

    struct Call: Sendable {
        var plan: LocalPipelineChunkPlan
        var sampleCount: Int
        var settings: LocalWhisperDecodingSettings
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private let mode: Mode

    init(mode: Mode = .success) {
        self.mode = mode
    }

    var runtimeDiagnostics: [String] {
        ["coreml_detected_path=none"]
    }

    func transcribe(
        plan: LocalPipelineChunkPlan,
        samples: ArraySlice<Float>,
        settings: LocalWhisperDecodingSettings
    ) throws -> LocalPipelineBaseChunkOutput {
        lock.lock()
        calls.append(Call(plan: plan, sampleCount: samples.count, settings: settings))
        lock.unlock()

        switch mode {
        case .success:
            if settings.purpose == .timingGuide {
                return LocalPipelineBaseChunkOutput(
                    chunkId: plan.chunkId,
                    engineType: SRTGenerationEngine.localPipeline.rawValue,
                    baseModel: settings.baseModel.rawValue,
                    language: settings.language,
                    segments: [
                        LocalPipelineBaseSegment(
                            segmentId: "\(plan.chunkId)-guide-0001",
                            start: plan.start + 0.1,
                            end: plan.start + 0.8,
                            text: "愛してるよ",
                            confidence: 0.92
                        ),
                        LocalPipelineBaseSegment(
                            segmentId: "\(plan.chunkId)-guide-0002",
                            start: plan.start + 1.05,
                            end: plan.start + 1.85,
                            text: "君のことを",
                            confidence: 0.88
                        ),
                        LocalPipelineBaseSegment(
                            segmentId: "\(plan.chunkId)-guide-0003",
                            start: plan.start + 3.1,
                            end: plan.start + 3.85,
                            text: "離さないよ",
                            confidence: 0.86
                        )
                    ]
                )
            }
            return LocalPipelineBaseChunkOutput(
                chunkId: plan.chunkId,
                engineType: SRTGenerationEngine.localPipeline.rawValue,
                baseModel: settings.baseModel.rawValue,
                language: settings.language,
                segments: [
                    LocalPipelineBaseSegment(
                        segmentId: "\(plan.chunkId)-seg-0001",
                        start: plan.start + 0.0,
                        end: plan.start + 0.9,
                        text: "愛してる",
                        confidence: 0.92
                    ),
                    LocalPipelineBaseSegment(
                        segmentId: "\(plan.chunkId)-seg-0002",
                        start: plan.start + 1.1,
                        end: plan.start + 1.9,
                        text: "君のこと",
                        confidence: 0.88
                    ),
                    LocalPipelineBaseSegment(
                        segmentId: "\(plan.chunkId)-seg-0003",
                        start: plan.start + 3.2,
                        end: plan.start + 3.9,
                        text: "離さない",
                        confidence: 0.86
                    )
                ]
            )
        case .empty:
            return LocalPipelineBaseChunkOutput(
                chunkId: plan.chunkId,
                engineType: SRTGenerationEngine.localPipeline.rawValue,
                baseModel: settings.baseModel.rawValue,
                language: settings.language,
                segments: [
                    LocalPipelineBaseSegment(
                        segmentId: "\(plan.chunkId)-seg-0001",
                        start: plan.start,
                        end: plan.start + 1.6,
                        text: "",
                        confidence: 0.92
                    )
                ]
            )
        }
    }

    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct MockWhisperTranscriberBuilder: LocalWhisperTranscriberBuilding {
    let transcriber: MockWhisperTranscriber

    func build(modelURL: URL) throws -> any LocalWhisperTranscribing {
        transcriber
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
        var lineSegmentIDs: [String]?
        var lineTexts: [String]?
        var lineStartTimes: [Double]?
        var lineEndTimes: [Double]?
        var lineSearchStartTimes: [Double]?
        var lineSearchEndTimes: [Double]?
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
    func assemblerNormalizesOverlappingTimings() {
        let assembler = LocalPipelineAssembler()
        let correctedSegments = [
            LocalPipelineCorrectedSegment(
                id: "1",
                segmentId: "block-1",
                startTime: 10.0,
                endTime: 15.0,
                baseTranscript: "a",
                finalTranscript: "a",
                corrections: []
            ),
            LocalPipelineCorrectedSegment(
                id: "2",
                segmentId: "block-2",
                startTime: 14.0,
                endTime: 18.0,
                baseTranscript: "b",
                finalTranscript: "b",
                corrections: []
            )
        ]

        let result = assembler.assemble(
            runId: "run-1",
            sourceFileName: "song.wav",
            baseModel: .kotobaWhisperV2,
            correctedSegments: correctedSegments
        )

        #expect(result.subtitles.count == 2)
        #expect(result.subtitles[0].endTime <= result.subtitles[1].startTime)
        #expect(result.subtitles[0].startTime == 10.0)
        #expect(result.subtitles[1].endTime == 18.0)
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

    @Test
    func draftBlocksSplitAcrossDetectedSpeechRegionsWithoutLyricsReference() {
        let service = LocalPipelineService()
        let textSegments = [
            LocalPipelineBaseSegment(segmentId: "chunk-00001-seg-0001", start: 0.0, end: 0.9, text: "愛してる", confidence: 0.9),
            LocalPipelineBaseSegment(segmentId: "chunk-00001-seg-0002", start: 1.0, end: 1.9, text: "君のこと", confidence: 0.88),
            LocalPipelineBaseSegment(segmentId: "chunk-00001-seg-0003", start: 3.1, end: 3.9, text: "離さない", confidence: 0.86)
        ]
        let speechRegions = [
            SpeechRegion(start: 0.0, end: 2.0),
            SpeechRegion(start: 3.0, end: 4.0)
        ]

        let draftSegments = service.buildDraftSegmentsFromTranscription(
            textSegments,
            timingGuideSegments: textSegments,
            speechRegions: speechRegions,
            totalDuration: 4.0
        )

        #expect(draftSegments.count == 2)
        #expect(draftSegments[0].text == "愛してる\n君のこと")
        #expect(draftSegments[1].text == "離さない")
    }

    @Test
    func mergesTinyNonReferenceSubtitlesWhenGapIsShallow() {
        let service = LocalPipelineService()
        let subtitles = [
            SubtitleItem(startTime: 0.0, endTime: 1.2, text: "約束したのに"),
            SubtitleItem(startTime: 1.22, endTime: 1.58, text: "角"),
            SubtitleItem(startTime: 1.62, endTime: 2.6, text: "花火の音が")
        ]

        let merged = service.mergeShortNonReferenceSubtitles(subtitles)

        #expect(merged.count == 2)
        #expect(merged[0].text == "約束したのに\n角")
        #expect(merged[0].endTime == 1.58)
        #expect(merged[1].text == "花火の音が")
    }

    @Test
    func draftBlocksSplitWhenCombinedLyricLengthGetsTooLong() {
        let service = LocalPipelineService()
        let textSegments = [
            LocalPipelineBaseSegment(segmentId: "chunk-00001-seg-0001", start: 0.0, end: 0.8, text: "約束はまだ", confidence: 0.9),
            LocalPipelineBaseSegment(segmentId: "chunk-00001-seg-0002", start: 0.86, end: 1.62, text: "胸の奥で", confidence: 0.88),
            LocalPipelineBaseSegment(segmentId: "chunk-00001-seg-0003", start: 1.7, end: 2.45, text: "燃えている", confidence: 0.87)
        ]
        let speechRegions = [SpeechRegion(start: 0.0, end: 3.0)]

        let draftSegments = service.buildDraftSegmentsFromTranscription(
            textSegments,
            timingGuideSegments: textSegments,
            speechRegions: speechRegions,
            totalDuration: 3.0
        )

        #expect(draftSegments.count == 2)
        #expect(draftSegments[0].text == "約束はまだ\n胸の奥で")
        #expect(draftSegments[1].text == "燃えている")
    }

    @Test
    func nonReferenceBoundariesMoveTowardQuietValley() {
        let service = LocalPipelineService()
        let sampleRate = 100.0
        var samples = Array(repeating: Float(0), count: 300)
        for index in 0..<95 { samples[index] = 0.18 }
        for index in 115..<200 { samples[index] = 0.2 }

        let subtitles = [
            SubtitleItem(startTime: 0.0, endTime: 1.08, text: "約束したのに"),
            SubtitleItem(startTime: 1.02, endTime: 2.08, text: "花火の音が")
        ]

        let optimized = service.optimizeNonReferenceSubtitles(
            subtitles,
            samples: samples,
            sampleRate: sampleRate
        )

        #expect(optimized.count == 2)
        #expect(optimized[0].endTime >= 0.95 && optimized[0].endTime <= 1.15)
        #expect(optimized[1].startTime >= 0.95 && optimized[1].startTime <= 1.15)
        #expect(optimized[0].endTime <= optimized[1].startTime)
    }

    @Test
    func nonReferenceAlignmentSearchWindowExpandsToSpeechRegionNeighbors() {
        let service = LocalPipelineService()
        let speechRegions = [
            SpeechRegion(start: 9.0, end: 11.0),
            SpeechRegion(start: 11.4, end: 12.8),
            SpeechRegion(start: 13.1, end: 14.0)
        ]

        let window = service.nonReferenceAlignmentSearchWindow(
            timing: (start: 11.5, end: 12.2),
            speechRegions: speechRegions,
            totalDuration: 20.0
        )

        #expect(window.start <= 8.7)
        #expect(window.end >= 14.3)
    }

    @Test
    func nonReferenceAlignmentGroupsNearbyDrafts() {
        let service = LocalPipelineService()
        let drafts = [
            LocalPipelineDraftSegment(segmentId: "block-00001", chunkId: "chunk-1", startTime: 10.0, endTime: 11.0, text: "約束したのに", sourceSegmentIDs: [], alignmentSearchStart: 9.0, alignmentSearchEnd: 12.5),
            LocalPipelineDraftSegment(segmentId: "block-00002", chunkId: "chunk-1", startTime: 11.2, endTime: 12.0, text: "花火の音が", sourceSegmentIDs: [], alignmentSearchStart: 9.0, alignmentSearchEnd: 12.5),
            LocalPipelineDraftSegment(segmentId: "block-00003", chunkId: "chunk-1", startTime: 13.2, endTime: 14.0, text: "遠くなる", sourceSegmentIDs: [], alignmentSearchStart: 13.0, alignmentSearchEnd: 14.5)
        ]

        let groups = service.makeAlignmentGroups(from: drafts)

        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].count == 1)
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
        #expect(snapshot.lastLyricsReference == nil)
        #expect(viewModel.status == .completed)
        #expect(viewModel.subtitles == result.subtitles)
        #expect(viewModel.lastLocalPipelineRunDirectoryURL == result.runDirectoryURL)
        #expect(viewModel.lastLocalPipelineResult?.finalSRTURL == result.finalSRTURL)
    }

    @MainActor
    @Test
    func appViewModelStripsCueNumbersAndTimestampsFromSRTLyricsReference() {
        let viewModel = AppViewModel()
        viewModel.applyLyricsReferenceText(
            """
            1
            00:00:08,520 --> 00:00:11,010
            Don't forget you

            2
            00:00:12,258 --> 00:00:16,328
            残暑お見舞い申し上げます
            """
        )

        #expect(
            viewModel.lyricsReferenceText
                == """
                Don't forget you
                残暑お見舞い申し上げます
                """
        )
        #expect(viewModel.lyricsReferenceInput?.sourceKind == .srt)
        #expect(viewModel.lyricsReferenceInput?.entries.count == 2)
        #expect(viewModel.lyricsReferenceInput?.entries.first?.sourceStart == 8.52)
        #expect(viewModel.lyricsReferenceInput?.entries.first?.sourceEnd == 11.01)
    }

    @MainActor
    @Test
    func appViewModelKeepsSRTReferenceTimingAfterEditing() {
        let viewModel = AppViewModel()
        viewModel.applyLyricsReferenceText(
            """
            1
            00:00:08,520 --> 00:00:11,010
            Don't forget you
            """
        )

        viewModel.updateLyricsReferenceEditorText(
            """
            Don't forget you
            残暑お見舞い申し上げます
            """
        )

        #expect(viewModel.lyricsReferenceInput?.sourceKind == .srt)
        #expect(viewModel.lyricsReferenceInput?.entries.count == 2)
        #expect(viewModel.lyricsReferenceInput?.entries.first?.sourceStart == 8.52)
        #expect(viewModel.lyricsReferenceInput?.entries.first?.sourceEnd == 11.01)
        #expect(viewModel.lyricsReferenceInput?.entries.last?.sourceStart != nil)
        #expect(viewModel.lyricsReferenceInput?.entries.last?.sourceEnd != nil)
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

        let ffmpegCandidates = resolver.candidateExecutableURLs(for: "ffmpeg")
        #expect(ffmpegCandidates.contains(URL(fileURLWithPath: "/custom/bin/ffmpeg")))
        #expect(ffmpegCandidates.contains(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")))
    }

    @Test
    func localPipelineServiceMatchesWhisperAndAeneasContract() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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

        var settings = LocalPipelineSettings.productionDefault
        settings.language = "ja"
        settings.initialPrompt = "曲名 夕焼け"
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.whisperCoreMLModelPath = coreMLURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner()
        let transcriber = MockWhisperTranscriber()
        let service = LocalPipelineService(
            processRunner: runner,
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: transcriber)
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: nil,
            progress: { _ in }
        )

        let requests = await runner.snapshot()
        #expect(requests.count == 1)

        let whisperCalls = transcriber.snapshot()
        #expect(whisperCalls.count == 2)
        #expect(whisperCalls.map(\.settings.purpose) == [.lyricsText, .timingGuide])
        #expect(whisperCalls.first?.settings.beamSize == settings.beamSize)
        #expect(whisperCalls.last?.settings.beamSize == 1)
        #expect(whisperCalls.last?.settings.initialPrompt == "")

        let prompt = try #require(whisperCalls.first?.settings.initialPrompt)
        let expectedBasePrompt = """
        日本語の歌詞です。
        字幕風ではなく、自然な歌詞として認識してください。
        意味の通る語のまとまりを優先し、不自然な語の分割を避けてください。
        聞こえない部分を創作せず、曖昧な箇所はそのまま控えめに出してください。
        文字化けした記号や不正な文字は出力しないでください。
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(normalizedPrompt.hasPrefix(expectedBasePrompt))
        #expect(prompt.contains("曲名 夕焼け"))

        let aeneasRequest = try #require(requests.first)
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
    func localPipelineUsesReferenceLyricsWhenProvided() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
              "rules": [{ "type": "exact", "from": "愛してるよ", "to": "愛してるよ" }]
            }
            """.utf8
        ).write(to: dictionaryURL)

        var settings = LocalPipelineSettings.productionDefault
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "愛してるよ\n君のことを\n離さないよ",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        let combined = result.subtitles.map(\.text).joined(separator: "\n")
        #expect(result.subtitles.count == 3)
        #expect(result.subtitles.map(\.text) == ["愛してるよ", "君のことを", "離さないよ"])
        #expect(combined == "愛してるよ\n君のことを\n離さないよ")
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
        #expect(result.subtitles[0].startTime < result.subtitles[1].startTime)
        #expect(result.subtitles[1].startTime < result.subtitles[2].startTime)
    }

    @Test
    func localPipelineAllowsMinorTXTReferenceMismatches() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "愛してるよ\n君のことを\n離さないよ\n夏の終わり",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.count == 4)
        #expect(result.subtitles.map(\.text) == ["愛してるよ", "君のことを", "離さないよ", "夏の終わり"])
    }

    @Test
    func txtReferencePreservesAlignmentInputAndGroupsNearbyLinesForAeneas() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目\n二行目\n三行目",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        let alignmentManifestURL = result.runDirectoryURL.appendingPathComponent("alignment_input/segments.json")
        #expect(FileManager.default.fileExists(atPath: alignmentManifestURL.path))

        let manifestData = try Data(contentsOf: alignmentManifestURL)
        let manifest = try JSONDecoder().decode(AlignmentManifestFixture.self, from: manifestData)
        #expect(manifest.segments.count == 2)
        #expect(manifest.segments.first?.lineSegmentIDs?.count == 2)
        #expect(manifest.segments.first?.lineTexts?.count == 2)
        #expect(manifest.segments.last?.lineSegmentIDs == nil)
        #expect(manifest.segments.last?.lineTexts == nil)
    }

    @Test
    func localPipelineKeepsTXTReferenceTextEvenWhenAlignmentIsWeak() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let referenceText = """
        スマホの画面スクロールして
        未練だけがくっきり残って
        夏が終わるのを見送ってる
        残暑お見舞い申し上げます
        ベランダで冷えたビール
        愛してるよ
        君のことを
        離さないよ
        """
        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: referenceText,
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.map(\.text) == referenceText.components(separatedBy: .newlines).filter { !$0.isEmpty })
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
        #expect(zip(result.subtitles, result.subtitles.dropFirst()).allSatisfy { $0.startTime <= $1.startTime && $0.endTime <= $1.startTime })
    }

    @Test
    func localPipelineUsesTXTReferenceWithTimingGuide() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let transcriber = MockWhisperTranscriber()
        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(alignmentMode: .emptyResult),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: transcriber)
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目\n二行目\n三行目",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.count == 3)
        // TXT参照時にも timing guide を生成（speech region 検出補助用）
        let snapshot = transcriber.snapshot()
        #expect(!snapshot.isEmpty)
        #expect(result.subtitles[0].startTime < 0.3)
        #expect(result.subtitles[1].startTime >= 0.8 && result.subtitles[1].startTime <= 1.4)
        #expect(result.subtitles[2].startTime >= 2.6)
    }

    @Test
    func localPipelineDistributesTXTReferenceAcrossMultipleSpeechRegions() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        let speechRegions = [(1.0, 2.5), (5.0, 7.0), (9.0, 10.5)]
        try writePatternedSpeechWAV(
            to: audioURL,
            durationSeconds: 12.0,
            speechRegions: speechRegions
        )

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(alignmentMode: .emptyResult),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目\n二行目\n三行目\n四行目\n五行目\n六行目",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.count == 6)
        #expect(result.subtitles[0].startTime >= 0.9 && result.subtitles[0].startTime <= 1.3)
        #expect(result.subtitles[2].startTime >= 4.9 && result.subtitles[2].startTime <= 5.4)
        #expect(result.subtitles.last?.startTime ?? 0 >= 8.9)
        #expect(result.subtitles.last?.endTime ?? 0 <= 10.6)
        #expect(result.subtitles.contains { $0.startTime >= 5.0 && $0.startTime <= 7.0 })
        #expect(result.subtitles.contains { $0.startTime >= 9.0 && $0.startTime <= 10.5 })
        #expect(zip(result.subtitles, result.subtitles.dropFirst()).allSatisfy { $0.startTime <= $1.startTime && $0.endTime <= $1.startTime })
    }

    @Test
    func localPipelineDoesNotOverShiftTXTBoundaryInsideMergedSpeechRegion() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        let speechRegions = [(1.0, 2.45), (2.95, 4.25), (6.4, 7.7)]
        try writePatternedSpeechWAV(
            to: audioURL,
            durationSeconds: 9.0,
            speechRegions: speechRegions
        )

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(alignmentMode: .emptyResult),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目の歌詞\n二行目の歌詞\n三行目の歌詞",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.count == 3)
        #expect(result.subtitles[0].endTime >= 2.3)
        #expect(result.subtitles[0].endTime <= 3.0)
        #expect(result.subtitles[1].startTime >= 2.3)
        #expect(result.subtitles[1].startTime <= 3.0)
        #expect(result.subtitles[2].startTime >= 6.2)
        #expect(zip(result.subtitles, result.subtitles.dropFirst()).allSatisfy { $0.startTime <= $1.startTime && $0.endTime <= $1.startTime })
    }

    @Test
    func localPipelineRejectsLargeAeneasShiftForTXTReference() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        let speechRegions = [(1.0, 2.5), (3.0, 4.3), (5.5, 6.8)]
        try writePatternedSpeechWAV(
            to: audioURL,
            durationSeconds: 8.0,
            speechRegions: speechRegions
        )

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(alignmentMode: .largeShift),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目\n二行目\n三行目",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles[0].startTime < 2.0)
        #expect(result.subtitles[1].startTime < 4.5)
        #expect(result.subtitles[2].startTime < 6.9)
    }

    @Test
    func localPipelineRejectsTXTAlignmentThatConsumesSingleLineSearchWindow() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        let speechRegions = [(2.0, 8.0)]
        try writePatternedSpeechWAV(
            to: audioURL,
            durationSeconds: 12.0,
            speechRegions: speechRegions
        )

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(alignmentMode: .clipEdgesForSingleLine),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目\n二行目\n三行目",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        let runLog = try String(contentsOf: result.runDirectoryURL.appendingPathComponent("logs/run.jsonl"), encoding: .utf8)
        #expect(runLog.contains("txt_clip_edge_guard"))
        #expect(result.subtitles.map(\.text) == ["一行目", "二行目", "三行目"])
    }

    @Test
    func localPipelinePreservesMeaningfulGapBetweenGroupedTXTLines() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        let speechRegions = [(2.0, 8.0)]
        try writePatternedSpeechWAV(
            to: audioURL,
            durationSeconds: 12.0,
            speechRegions: speechRegions
        )

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(alignmentMode: .gappedGrouped),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目\n二行目\n三行目",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.count == 3)
        let gap = result.subtitles[1].startTime - result.subtitles[0].endTime
        #expect(gap >= 0.45)
    }

    @Test
    func localPipelineCompletesTXTReferenceEvenWithoutGuideOrSpeech() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeSilentWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber(mode: .empty))
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "一行目\n二行目\n三行目",
                sourceName: "lyrics.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.map(\.text) == ["一行目", "二行目", "三行目"])
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
        #expect(zip(result.subtitles, result.subtitles.dropFirst()).allSatisfy { $0.startTime <= $1.startTime && $0.endTime <= $1.startTime })
    }

    @Test
    func localPipelineKeepsReferenceSRTTimingWhenAeneasReturnsNothing() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(alignmentMode: .emptyResult),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let referenceEntries = [
            ReferenceLyricEntry(text: "愛してるよ", sourceStart: 0.2, sourceEnd: 1.0, sourceIndex: 0),
            ReferenceLyricEntry(text: "君のことを", sourceStart: 1.2, sourceEnd: 2.0, sourceIndex: 1),
            ReferenceLyricEntry(text: "離さないよ", sourceStart: 3.0, sourceEnd: 3.8, sourceIndex: 2),
        ]
        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: referenceEntries.map(\.text).joined(separator: "\n"),
                sourceName: "lyrics.srt",
                sourceKind: .srt,
                entries: referenceEntries
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.count == 3)
        #expect(result.subtitles.map(\.text) == referenceEntries.map(\.text))
        #expect(abs(result.subtitles[0].startTime - 0.2) < 0.8)
        #expect(abs(result.subtitles[1].startTime - 1.2) < 0.8)
        #expect(abs(result.subtitles[2].startTime - 3.0) < 0.8)
    }

    @Test
    func localPipelineKeepsReferenceLyricsEvenWhenContentLooksDifferent() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let service = LocalPipelineService(
            processRunner: MockExternalProcessRunner(),
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: LocalLyricsReferenceInput(
                text: "まったく違う曲の歌詞です\nこの音声とは合いません",
                sourceName: "other.txt"
            ),
            progress: { _ in }
        )

        #expect(result.subtitles.map(\.text) == ["まったく違う曲の歌詞です", "この音声とは合いません"])
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
    }

    @Test
    func localPipelineFallsBackToWhisperTimingWhenOnlySomeBlocksMissAlignment() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner(alignmentMode: .partialFallback)
        let service = LocalPipelineService(
            processRunner: runner,
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: nil,
            progress: { _ in }
        )

        #expect(result.subtitles.count == 2)
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
        #expect((result.subtitles.first?.startTime ?? -1) >= 0)
        #expect((result.subtitles.first?.endTime ?? -1) > (result.subtitles.first?.startTime ?? 0))
        #expect((result.subtitles.last?.startTime ?? -1) >= (result.subtitles.first?.endTime ?? 0))
        #expect((result.subtitles.last?.endTime ?? -1) > (result.subtitles.last?.startTime ?? 0))
    }

    @Test
    func localPipelineFallsBackWhenAeneasProducesNoAlignedBlocks() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner(alignmentMode: .emptyResult)
        let service = LocalPipelineService(
            processRunner: runner,
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber())
        )

        let result = try await service.analyze(
            fileURL: audioURL,
            settings: settings,
            lyricsReference: nil,
            progress: { _ in }
        )

        #expect(!result.subtitles.isEmpty)
        #expect(result.subtitles.allSatisfy { $0.endTime > $0.startTime })
    }

    @Test
    func localPipelineFailsWhenWhisperReturnsNoUsableText() async throws {
        let sandboxURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxURL) }

        let audioURL = sandboxURL.appendingPathComponent("input.wav")
        try writeTestWAV(to: audioURL)

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
        settings.aeneasPythonPath = pythonURL.path
        settings.aeneasScriptPath = aeneasScriptURL.path
        settings.whisperModelPath = whisperModelURL.path
        settings.correctionDictionaryPath = dictionaryURL.path
        settings.outputDirectoryPath = sandboxURL.appendingPathComponent("Work", isDirectory: true).path

        let runner = MockExternalProcessRunner()
        let service = LocalPipelineService(
            processRunner: runner,
            whisperTranscriberBuilder: MockWhisperTranscriberBuilder(transcriber: MockWhisperTranscriber(mode: .empty))
        )

        await #expect(throws: LocalPipelineError.emptyTranscription("ローカル字幕を生成できませんでした。音声から歌詞を読み取れませんでした。")) {
            try await service.analyze(
                fileURL: audioURL,
                settings: settings,
                lyricsReference: nil,
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

private func writeSilentWAV(to url: URL) throws {
    let sampleRate = 16_000
    let durationSeconds = 4.0
    let frameCount = Int(Double(sampleRate) * durationSeconds)
    let pcm = Data(repeating: 0, count: frameCount * 2)

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

private func writePatternedSpeechWAV(
    to url: URL,
    durationSeconds: Double,
    speechRegions: [(Double, Double)]
) throws {
    let sampleRate = 16_000
    let frameCount = Int(Double(sampleRate) * durationSeconds)
    var pcm = Data(capacity: frameCount * 2)

    for index in 0..<frameCount {
        let time = Double(index) / Double(sampleRate)
        let isSpeech = speechRegions.contains { start, end in
            time >= start && time < end
        }
        let sample: Int16
        if isSpeech {
            let angle = time * 2 * Double.pi * 440
            sample = Int16((sin(angle) * 12_000).rounded())
        } else {
            sample = 0
        }
        var little = sample.littleEndian
        withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
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
