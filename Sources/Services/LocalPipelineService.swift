@preconcurrency import AVFoundation
import Foundation

final class LocalPipelineService: LocalPipelineAnalyzing, @unchecked Sendable {
    private static let minimumStandaloneSubtitleDuration: TimeInterval = 0.35
    private static let draftTargetDuration: TimeInterval = 4.8
    private static let draftMaxDuration: TimeInterval = 7.5
    private static let draftMaxLines = 2
    private static let alignmentPadding: TimeInterval = 0.45
    private static let alignmentTimeoutPerBlock: TimeInterval = 45
    private static let preserveIntermediateArtifacts = false
    private static let retryNoSpeechThreshold = 0.2
    private static let rescueChunkOverlapSeconds: TimeInterval = 0.4
    private static let preferredBaseSegmentDuration: TimeInterval = 4.2
    private static let rescueChunkTargetDuration: TimeInterval = 3.0
    private static let tokenSegmentTargetCharacters = 6
    private static let tokenSegmentMaxCharacters = 8
    private static let tokenSegmentHardMaxDuration: TimeInterval = 3.2
    private static let tokenSegmentStrongGap: TimeInterval = 0.28
    private static let tokenSegmentSoftGap: TimeInterval = 0.16
    private static let referenceSRTSearchPad: TimeInterval = 0.6
    private static let referenceSRTMaxShift: TimeInterval = 0.8
    private static let referenceSRTAlignmentPadding: TimeInterval = 0.2
    private static let vadWindowSize: TimeInterval = 0.01
    private static let vadMinGapFill: TimeInterval = 0.18
    private static let vadMinRegionDuration: TimeInterval = 0.12
    private static let vadMergeGap: TimeInterval = 0.2
    private static let txtAlignmentPadding: TimeInterval = 1.2
    private static let unmatchedLinePenalty = 3.4
    private static let skippedRegionPenalty = 1.3
    private static let aeneasMaxShift: TimeInterval = 2.5
    private static let localWaveformAlignmentConfig = AlignmentConfig(
        searchWindowPad: 2.0,
        rmsWindowSize: 0.005,
        thresholdRatio: 0.12,
        minVolumeAbsolute: 0.002,
        padStart: 0.15,
        padEnd: 0.25,
        maxSnapDistance: 1.0,
        minGapFill: 0.3,
        useAdaptiveThreshold: true
    )
    private static let whisperBasePrompt = """
日本語の歌詞です。
字幕風ではなく、自然な歌詞として認識してください。
意味の通る語のまとまりを優先し、不自然な語の分割を避けてください。
聞こえない部分を創作せず、曖昧な箇所はそのまま控えめに出してください。
文字化けした記号や不正な文字は出力しないでください。
"""

    private struct ResolvedPaths {
        var pythonExecutableURL: URL
        var whisperModelURL: URL
        var whisperCoreMLModelURL: URL?
        var aeneasScriptURL: URL
    }

    private struct AlignmentInputSegment: Codable {
        var segmentId: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var text: String
        var audioPath: String
        var clipStartTime: TimeInterval
    }

    private struct AlignmentInputManifest: Codable {
        var runId: String
        var sourceFileName: String
        var language: String
        var segments: [AlignmentInputSegment]
    }

    private struct WhisperTokenPiece {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var confidence: Double
    }

    private struct SpeechRegion: Equatable {
        var start: TimeInterval
        var end: TimeInterval
    }

    private struct GuideRegion: Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var sourceSegmentIDs: [String]
    }

    private struct TimingGuideAnchor {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var confidence: Double
        var sourceSegmentIDs: [String]
    }

    private struct ReferenceAlignmentMatch {
        var entry: ReferenceLyricEntry
        var region: GuideRegion?
        var wasUnmatched: Bool
    }

    private struct AlignmentState {
        var cost: Double
        var lastMatchedEnd: TimeInterval?
    }

    private actor AlignmentProgressTracker {
        private var buffer = ""
        private let totalBlocks: Int
        private let progress: @Sendable (LocalPipelineProgress) async -> Void

        init(
            totalBlocks: Int,
            progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
        ) {
            self.totalBlocks = max(totalBlocks, 1)
            self.progress = progress
        }

        func consume(_ data: Data) async {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            buffer.append(text)

            while let newlineIndex = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                await handle(line)
            }
        }

        private func handle(_ line: String) async {
            guard let marker = line.range(of: "Aligning block ") else { return }
            let suffix = line[marker.upperBound...]
            guard let colonIndex = suffix.firstIndex(of: ":") else { return }
            let fraction = suffix[..<colonIndex]
            let parts = fraction.split(separator: "/")
            guard parts.count == 2,
                  let current = Int(parts[0]),
                  let total = Int(parts[1]),
                  total > 0 else {
                return
            }

            let safeTotal = max(totalBlocks, total)
            let ratio = Double(min(current, safeTotal)) / Double(safeTotal)
            await progress(
                LocalPipelineProgress(
                    phase: .aligning,
                    message: "解析中...",
                    currentChunk: min(current, safeTotal),
                    totalChunks: safeTotal,
                    displayPercent: 60 + ratio * 25
                )
            )
        }
    }

    private let processRunner: any ExternalProcessRunning
    private let whisperTranscriberBuilder: any LocalWhisperTranscriberBuilding
    private let runDirectoryBuilder: RunDirectoryBuilder
    private let correctionService: LocalPipelineCorrectionService
    private let assembler: LocalPipelineAssembler
    private let runtimePathResolver: AppRuntimePathResolver
    private let waveformService = WaveformService()
    private let jsonEncoder: JSONEncoder

    init(
        processRunner: any ExternalProcessRunning = ExternalProcessRunner(),
        whisperTranscriberBuilder: any LocalWhisperTranscriberBuilding = WhisperSPMTranscriberBuilder(),
        runDirectoryBuilder: RunDirectoryBuilder = RunDirectoryBuilder(),
        correctionService: LocalPipelineCorrectionService = LocalPipelineCorrectionService(),
        assembler: LocalPipelineAssembler = LocalPipelineAssembler(),
        runtimePathResolver: AppRuntimePathResolver = AppRuntimePathResolver()
    ) {
        self.processRunner = processRunner
        self.whisperTranscriberBuilder = whisperTranscriberBuilder
        self.runDirectoryBuilder = runDirectoryBuilder
        self.correctionService = correctionService
        self.assembler = assembler
        self.runtimePathResolver = runtimePathResolver
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func analyze(
        fileURL: URL,
        settings: LocalPipelineSettings,
        lyricsReference: LocalLyricsReferenceInput?,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> LocalPipelineResult {
        let validatedPaths = try validate(settings: settings)
        let sourceFileName = fileURL.lastPathComponent
        let sourceDuration = try waveformService.audioDuration(url: fileURL)
        let buildResult = try runDirectoryBuilder.build(
            sourceFileName: sourceFileName,
            sourceDuration: sourceDuration,
            settings: settings,
            engineType: .localPipeline
        )
        let layout = buildResult.layout
        var manifest = buildResult.manifest
        let logger = RunLogger(logURL: layout.runLogURL)
        let resolvedPaths = try prepareRuntimePaths(validatedPaths, layout: layout)
        let whisperTranscriber = try whisperTranscriberBuilder.build(modelURL: resolvedPaths.whisperModelURL)
        try appendStderr(
            Data((whisperTranscriber.runtimeDiagnostics.joined(separator: "\n") + "\n").utf8),
            to: layout.whisperStderrURL,
            header: "==== whisper runtime ====\n"
        )

        await reportProgress(
            progress,
            phase: .validating,
            message: "音声読込中...",
            currentChunk: 0,
            totalChunks: 0,
            displayPercent: 3
        )

        let normalized = try waveformService.convertedMonoSamples(url: fileURL, targetSampleRate: 16_000)
        let normalizedURL = layout.inputDirectoryURL.appendingPathComponent("normalized.wav")
        try writePCM16WAV(samples: normalized.samples, sampleRate: normalized.sampleRate, to: normalizedURL)
        try runDirectoryBuilder.markStage(.normalized, manifest: &manifest, at: layout.manifestURL)
        try logger.log(
            runId: manifest.runId,
            stage: LocalPipelinePhase.preparing.rawValue,
            level: .info,
            message: "normalized wav written",
            engineType: .localPipeline,
            stderrPath: layout.whisperStderrURL
        )

        await reportProgress(
            progress,
            phase: .preparing,
            message: "音声準備中...",
            currentChunk: 0,
            totalChunks: 0,
            displayPercent: 10
        )

        let chunkPlans = try makeChunkPlans(
            samples: normalized.samples,
            sampleRate: normalized.sampleRate,
            chunkLengthSeconds: settings.chunkLengthSeconds,
            overlapSeconds: settings.overlapSeconds
        )
        let chunksIndex = LocalPipelineChunksIndex(
            runId: manifest.runId,
            sourceDuration: normalized.duration,
            chunkLengthSeconds: settings.chunkLengthSeconds,
            overlapSeconds: settings.overlapSeconds,
            chunks: chunkPlans
        )
        try writeJSON(chunksIndex, to: layout.chunksDirectoryURL.appendingPathComponent("index.json"))
        try runDirectoryBuilder.markStage(.chunked, manifest: &manifest, at: layout.manifestURL)

        await reportProgress(
            progress,
            phase: .chunking,
            message: "分割中...",
            currentChunk: 0,
            totalChunks: chunkPlans.count,
            displayPercent: 15
        )

        let usesReferenceSRTTiming = lyricsReference?.sourceKind == .srt
            && lyricsReference?.entries.isEmpty == false
            && lyricsReference?.entries.allSatisfy({ $0.sourceStart != nil && $0.sourceEnd != nil }) == true

        let textChunkResults: [(plan: LocalPipelineChunkPlan, output: LocalPipelineBaseChunkOutput)]
        let timingChunkResults: [(plan: LocalPipelineChunkPlan, output: LocalPipelineBaseChunkOutput)]

        if lyricsReference == nil {
            textChunkResults = try await runBaseTranscription(
                runId: manifest.runId,
                plans: chunkPlans,
                normalizedSamples: normalized.samples,
                sampleRate: normalized.sampleRate,
                layout: layout,
                decodingSettings: whisperDecodingSettings(from: settings, purpose: .lyricsText),
                whisperTranscriber: whisperTranscriber,
                logger: logger,
                displayStartPercent: 20,
                displayPercentSpan: 20,
                progress: progress
            )
            timingChunkResults = try await runBaseTranscription(
                runId: manifest.runId,
                plans: chunkPlans,
                normalizedSamples: normalized.samples,
                sampleRate: normalized.sampleRate,
                layout: layout,
                decodingSettings: whisperDecodingSettings(from: settings, purpose: .timingGuide),
                whisperTranscriber: whisperTranscriber,
                logger: logger,
                displayStartPercent: 40,
                displayPercentSpan: 15,
                progress: progress
            )
        } else if usesReferenceSRTTiming {
            textChunkResults = []
            timingChunkResults = []
        } else {
            textChunkResults = []
            timingChunkResults = []
        }
        try runDirectoryBuilder.markStage(.baseTranscribed, manifest: &manifest, at: layout.manifestURL)

        let preparedTextSegments = prepareDraftSourceSegments(from: textChunkResults)
        let mergedTextSegments = postprocessLyricsSegments(preparedTextSegments)
        let timingGuideSegments = prepareTimingGuideSegments(from: timingChunkResults)
        guard !mergedTextSegments.isEmpty || lyricsReference != nil else {
            try logger.log(
                runId: manifest.runId,
                stage: LocalPipelinePhase.baseTranscribing.rawValue,
                level: .error,
                message: "empty transcription",
                engineType: .localPipeline,
                stderrPath: layout.whisperStderrURL
            )
            throw LocalPipelineError.emptyTranscription("ローカル字幕を生成できませんでした。音声から歌詞を読み取れませんでした。")
        }

        let draftSegments = try buildDraftSegments(
            textSegments: mergedTextSegments,
            timingGuideSegments: timingGuideSegments,
            lyricsReference: lyricsReference,
            normalizedAudioURL: normalizedURL,
            normalizedSamples: normalized.samples,
            sampleRate: normalized.sampleRate,
            logger: logger,
            runId: manifest.runId
        )
        guard !draftSegments.isEmpty else {
            try logger.log(
                runId: manifest.runId,
                stage: LocalPipelinePhase.chunking.rawValue,
                level: .error,
                message: "empty subtitles",
                engineType: .localPipeline
            )
            throw LocalPipelineError.emptyTranscription("ローカル字幕を生成できませんでした。音声から歌詞を読み取れませんでした。")
        }
        await reportProgress(
            progress,
            phase: .aligning,
            message: "解析中...",
            currentChunk: 0,
            totalChunks: draftSegments.count,
            displayPercent: 60
        )

        let alignedSegments = try await runAlignment(
            runId: manifest.runId,
            sourceFileName: sourceFileName,
            draftSegments: draftSegments,
            normalizedSamples: normalized.samples,
            sampleRate: normalized.sampleRate,
            layout: layout,
            settings: settings,
            allowsReferenceFallback: true,
            resolvedPaths: resolvedPaths,
            logger: logger,
            progress: progress
        )
        try runDirectoryBuilder.markStage(.aligned, manifest: &manifest, at: layout.manifestURL)

        await reportProgress(
            progress,
            phase: .correcting,
            message: "整形中...",
            currentChunk: draftSegments.count,
            totalChunks: draftSegments.count,
            displayPercent: 88
        )

        let correctedSegments = try correctionService.correct(
            runId: manifest.runId,
            draftSegments: draftSegments,
            alignedSegments: alignedSegments,
            settings: settings,
            allowDictionaryCorrections: lyricsReference == nil
        )
        try runDirectoryBuilder.markStage(.corrected, manifest: &manifest, at: layout.manifestURL)

        let assembly = assembler.assemble(
            runId: manifest.runId,
            sourceFileName: sourceFileName,
            baseModel: settings.baseModel,
            correctedSegments: correctedSegments
        )
        let refinedSubtitles = try await refineSubtitlesForWaveform(
            assembly.subtitles,
            fallbackSubtitles: assembly.subtitles,
            hasReferenceLyrics: lyricsReference != nil,
            normalizedAudioURL: normalizedURL,
            normalizedSamples: normalized.samples,
            sampleRate: normalized.sampleRate
        )
        guard !refinedSubtitles.isEmpty else {
            try logger.log(
                runId: manifest.runId,
                stage: LocalPipelinePhase.assembling.rawValue,
                level: .error,
                message: "empty subtitles",
                engineType: .localPipeline
            )
            throw LocalPipelineError.emptyTranscription("ローカル字幕を生成できませんでした。音声から歌詞を読み取れませんでした。")
        }

        await reportProgress(
            progress,
            phase: .writingOutputs,
            message: "まとめ中...",
            currentChunk: assembly.subtitles.count,
            totalChunks: assembly.subtitles.count,
            displayPercent: 96
        )

        let finalSRTURL = layout.finalDirectoryURL.appendingPathComponent("final.srt")
        try writeText(SRTCodec.generateSRT(from: refinedSubtitles), to: finalSRTURL)
        try runDirectoryBuilder.markStage(.outputsWritten, manifest: &manifest, at: layout.manifestURL)
        try logger.log(
            runId: manifest.runId,
            stage: LocalPipelinePhase.writingOutputs.rawValue,
            level: .info,
            message: "final srt written",
            engineType: .localPipeline
        )

        await reportProgress(
            progress,
            phase: .writingOutputs,
            message: "完了",
            currentChunk: assembly.subtitles.count,
            totalChunks: assembly.subtitles.count,
            displayPercent: 100
        )

        if !Self.preserveIntermediateArtifacts {
            try cleanupSuccessfulRunArtifacts(layout: layout)
        }

        return LocalPipelineResult(
            subtitles: refinedSubtitles,
            runDirectoryURL: layout.rootURL,
            finalSRTURL: finalSRTURL
        )
    }

    private func validate(settings: LocalPipelineSettings) throws -> ResolvedPaths {
        guard settings.chunkLengthSeconds > 0 else {
            throw LocalPipelineError.invalidConfiguration("chunkLengthSeconds must be greater than 0.")
        }
        guard settings.overlapSeconds >= 0 else {
            throw LocalPipelineError.invalidConfiguration("overlapSeconds must not be negative.")
        }
        guard settings.chunkLengthSeconds > settings.overlapSeconds else {
            throw LocalPipelineError.invalidConfiguration("chunkLengthSeconds must be larger than overlapSeconds.")
        }

        let pythonExecutableURL = try resolveExecutable(settings.aeneasPythonPath, label: "aeneas python")
        let whisperModelURL = try resolveWhisperModel(settings: settings)
        let whisperCoreMLModelURL: URL?
        let trimmedCoreML = settings.whisperCoreMLModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCoreML.isEmpty {
            whisperCoreMLModelURL = nil
        } else {
            whisperCoreMLModelURL = try resolveReadableFile(trimmedCoreML, label: "whisper Core ML model")
        }
        let aeneasScriptURL = try resolveReadableFile(settings.aeneasScriptPath, label: "aeneas script")

        return ResolvedPaths(
            pythonExecutableURL: pythonExecutableURL,
            whisperModelURL: whisperModelURL,
            whisperCoreMLModelURL: whisperCoreMLModelURL,
            aeneasScriptURL: aeneasScriptURL
        )
    }

    private func runBaseTranscription(
        runId: String,
        plans: [LocalPipelineChunkPlan],
        normalizedSamples: [Float],
        sampleRate: Double,
        layout: RunDirectoryLayout,
        decodingSettings: LocalWhisperDecodingSettings,
        whisperTranscriber: any LocalWhisperTranscribing,
        logger: RunLogger,
        displayStartPercent: Double,
        displayPercentSpan: Double,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> [(plan: LocalPipelineChunkPlan, output: LocalPipelineBaseChunkOutput)] {
        var results: [(LocalPipelineChunkPlan, LocalPipelineBaseChunkOutput)] = []
        results.reserveCapacity(plans.count)

        for (index, plan) in plans.enumerated() {
            await reportProgress(
                progress,
                phase: .baseTranscribing,
                message: "解析中...",
                currentChunk: index + 1,
                totalChunks: plans.count,
                displayPercent: displayStartPercent + (Double(index) / Double(max(plans.count, 1))) * displayPercentSpan
            )

            let chunkSamples = extractSamples(
                from: normalizedSamples,
                sampleRate: sampleRate,
                start: plan.start,
                end: plan.end
            )
            let chunkURL = layout.chunksDirectoryURL.appendingPathComponent("\(plan.chunkId).wav")
            try writePCM16WAV(samples: chunkSamples, sampleRate: sampleRate, to: chunkURL)

            do {
                var output = try whisperTranscriber.transcribe(
                    plan: plan,
                    samples: chunkSamples,
                    settings: decodingSettings
                )
                try appendStderr(
                    Data("whisper.cpp C API transcription completed\n".utf8),
                    to: layout.whisperStderrURL,
                    header: "==== \(plan.chunkId) ====\n"
                )
                if decodingSettings.purpose != .timingGuide && shouldRetryBaseTranscription(output) {
                    let retried = try await retryBaseTranscriptionIfNeeded(
                        currentOutput: output,
                        plan: plan,
                        chunkSamples: chunkSamples,
                        normalizedSamples: normalizedSamples,
                        sampleRate: sampleRate,
                        layout: layout,
                        decodingSettings: decodingSettings,
                        whisperTranscriber: whisperTranscriber,
                        runId: runId,
                        logger: logger
                    )
                    output = retried ?? output
                }
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.baseTranscribing.rawValue,
                    level: .info,
                    message: "chunk completed",
                    engineType: .localPipeline,
                    chunkId: plan.chunkId,
                    stderrPath: layout.whisperStderrURL
                )
                results.append((plan, output))
            } catch {
                let pipelineError = wrapWhisperError(error)
                try appendStderr(
                    Data("\(pipelineError.localizedDescription)\n".utf8),
                    to: layout.whisperStderrURL,
                    header: "==== \(plan.chunkId) ====\n"
                )
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.baseTranscribing.rawValue,
                    level: .error,
                    message: "whisper.cpp c api failed",
                    engineType: .localPipeline,
                    chunkId: plan.chunkId,
                    stderrPath: layout.whisperStderrURL
                )
                throw pipelineError
            }
        }

        return results
    }

    private func shouldRetryBaseTranscription(_ output: LocalPipelineBaseChunkOutput) -> Bool {
        let nonGarbage = output.segments.filter { !isObviouslyGarbageTranscript($0.text, confidence: $0.confidence) }
        guard !nonGarbage.isEmpty else { return true }
        if containsSuspiciousBaseSegments(output.segments) {
            return true
        }
        if nonGarbage.count == 1, let segment = nonGarbage.first {
            let duration = segment.end - segment.start
            if duration >= 5.5 {
                return true
            }
        }
        return false
    }

    private func containsSuspiciousBaseSegments(_ segments: [LocalPipelineBaseSegment]) -> Bool {
        for segment in segments {
            let normalized = normalizedText(segment.text)
            if normalized.isEmpty {
                return true
            }
            if normalized.count == 1 {
                return true
            }
            if normalized.allSatisfy({ $0.isNumber }) {
                return true
            }
            let latin = normalized.filter { $0.isASCII && $0.isLetter }
            if !latin.isEmpty && latin.count == normalized.count && normalized.count <= 2 {
                return true
            }
        }
        return false
    }

    private func retryBaseTranscriptionIfNeeded(
        currentOutput: LocalPipelineBaseChunkOutput,
        plan: LocalPipelineChunkPlan,
        chunkSamples: [Float],
        normalizedSamples: [Float],
        sampleRate: Double,
        layout: RunDirectoryLayout,
        decodingSettings: LocalWhisperDecodingSettings,
        whisperTranscriber: any LocalWhisperTranscribing,
        runId: String,
        logger: RunLogger
    ) async throws -> LocalPipelineBaseChunkOutput? {
        var retrySettings = decodingSettings
        retrySettings.noSpeechThreshold = min(decodingSettings.noSpeechThreshold, Self.retryNoSpeechThreshold)
        let retriedOutput = try whisperTranscriber.transcribe(
            plan: plan,
            samples: chunkSamples,
            settings: retrySettings
        )
        try appendStderr(
            Data("whisper.cpp C API retry completed\n".utf8),
            to: layout.whisperStderrURL,
            header: "==== \(plan.chunkId)-retry ====\n"
        )
        let currentUseful = currentOutput.segments.filter { !isObviouslyGarbageTranscript($0.text, confidence: $0.confidence) }.count
        let retriedUseful = retriedOutput.segments.filter { !isObviouslyGarbageTranscript($0.text, confidence: $0.confidence) }.count
        if retriedUseful > currentUseful {
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.baseTranscribing.rawValue,
                level: .warn,
                message: "whisper.cpp retry recovered chunk",
                engineType: .localPipeline,
                chunkId: plan.chunkId,
                stderrPath: layout.whisperStderrURL
            )
            return retriedOutput
        }

        let rescuedOutput = try await rescueBaseTranscriptionBySubdividingChunk(
            plan: plan,
            normalizedSamples: normalizedSamples,
            sampleRate: sampleRate,
            layout: layout,
            decodingSettings: decodingSettings,
            whisperTranscriber: whisperTranscriber,
            currentUsefulSegmentCount: currentUseful,
            runId: runId,
            logger: logger
        )
        if let rescuedOutput {
            return rescuedOutput
        }

        return nil
    }

    private func rescueBaseTranscriptionBySubdividingChunk(
        plan: LocalPipelineChunkPlan,
        normalizedSamples: [Float],
        sampleRate: Double,
        layout: RunDirectoryLayout,
        decodingSettings: LocalWhisperDecodingSettings,
        whisperTranscriber: any LocalWhisperTranscribing,
        currentUsefulSegmentCount: Int,
        runId: String,
        logger: RunLogger
    ) async throws -> LocalPipelineBaseChunkOutput? {
        let overlap = min(Self.rescueChunkOverlapSeconds, max(0.1, (plan.end - plan.start) / 8))
        let stride = max(0.8, Self.rescueChunkTargetDuration - overlap)
        var rescuePlans: [LocalPipelineChunkPlan] = []
        var cursor = plan.start
        var index = 1

        while cursor < plan.end - 0.2 {
            let end = min(plan.end, cursor + Self.rescueChunkTargetDuration + overlap)
            rescuePlans.append(
                LocalPipelineChunkPlan(
                    chunkId: "\(plan.chunkId)-rescue-\(index)",
                    start: max(plan.start, cursor - overlap),
                    end: end
                )
            )
            if end >= plan.end {
                break
            }
            cursor += stride
            index += 1
        }

        var rescuedSegments: [LocalPipelineBaseSegment] = []
        var rescueSettings = decodingSettings
        rescueSettings.noSpeechThreshold = min(decodingSettings.noSpeechThreshold, Self.retryNoSpeechThreshold)

        for rescuePlan in rescuePlans {
            let rescueChunkURL = layout.chunksDirectoryURL.appendingPathComponent("\(rescuePlan.chunkId).wav")
            let rescueChunkSamples = extractSamples(
                from: normalizedSamples,
                sampleRate: sampleRate,
                start: rescuePlan.start,
                end: rescuePlan.end
            )
            try writePCM16WAV(samples: rescueChunkSamples, sampleRate: sampleRate, to: rescueChunkURL)

            let output = try whisperTranscriber.transcribe(
                plan: rescuePlan,
                samples: rescueChunkSamples,
                settings: rescueSettings
            )
            try appendStderr(
                Data("whisper.cpp C API rescue completed\n".utf8),
                to: layout.whisperStderrURL,
                header: "==== \(rescuePlan.chunkId) ====\n"
            )
            rescuedSegments.append(contentsOf: output.segments)
        }

        let mergedRescuedSegments = mergeRawBaseSegments(rescuedSegments)
        let usefulRescuedSegments = mergedRescuedSegments.filter {
            !isObviouslyGarbageTranscript($0.text, confidence: $0.confidence)
        }
        guard usefulRescuedSegments.count > currentUsefulSegmentCount else {
            return nil
        }

        let rescuedOutput = LocalPipelineBaseChunkOutput(
            chunkId: plan.chunkId,
            engineType: SRTGenerationEngine.localPipeline.rawValue,
            baseModel: decodingSettings.baseModel.rawValue,
            language: decodingSettings.language,
            segments: usefulRescuedSegments
        )

        try logger.log(
            runId: runId,
            stage: LocalPipelinePhase.baseTranscribing.rawValue,
            level: .warn,
            message: "whisper.cpp rescue split chunk recovered more segments",
            engineType: .localPipeline,
            chunkId: plan.chunkId,
            stderrPath: layout.whisperStderrURL
        )
        return rescuedOutput
    }

    private func mergeBaseSegments(
        from chunkResults: [(plan: LocalPipelineChunkPlan, output: LocalPipelineBaseChunkOutput)]
    ) -> [LocalPipelineBaseSegment] {
        let rawSegments = chunkResults
            .flatMap(\.output.segments)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.start == $1.start {
                    return $0.end < $1.end
                }
                return $0.start < $1.start
            }

        return mergeRawBaseSegments(rawSegments)
    }

    private func mergeRawBaseSegments(_ rawSegments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
        var merged: [LocalPipelineBaseSegment] = []
        for segment in rawSegments {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }

            if shouldMergeOrSkipDuplicate(last: last, current: segment) {
                let mergedSegment = LocalPipelineBaseSegment(
                    segmentId: last.segmentId,
                    start: min(last.start, segment.start),
                    end: max(last.end, segment.end),
                    text: last.text.count >= segment.text.count ? last.text : segment.text,
                    confidence: max(last.confidence, segment.confidence)
                )
                merged[merged.count - 1] = mergedSegment
                continue
            }

            merged.append(segment)
        }

        return merged
    }

    private func prepareDraftSourceSegments(
        from chunkResults: [(plan: LocalPipelineChunkPlan, output: LocalPipelineBaseChunkOutput)]
    ) -> [LocalPipelineBaseSegment] {
        let merged = mergeBaseSegments(from: chunkResults)
        let split = merged.flatMap(splitLongBaseSegment(_:))
        return split.filter { !isObviouslyGarbageTranscript($0.text, confidence: $0.confidence) }
    }

    private func prepareTimingGuideSegments(
        from chunkResults: [(plan: LocalPipelineChunkPlan, output: LocalPipelineBaseChunkOutput)]
    ) -> [LocalPipelineBaseSegment] {
        let merged = mergeBaseSegments(from: chunkResults)
        return merged.compactMap { segment in
            let normalizedText = normalizeLyricsText(segment.text)
            guard !normalizedText.isEmpty else { return nil }
            return LocalPipelineBaseSegment(
                segmentId: segment.segmentId,
                start: segment.start,
                end: segment.end,
                text: normalizedText,
                confidence: segment.confidence
            )
        }
    }

    private func postprocessLyricsSegments(_ segments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
        let cleaned = segments.compactMap { segment -> LocalPipelineBaseSegment? in
            let normalizedText = normalizeLyricsText(segment.text)
            guard !normalizedText.isEmpty else { return nil }

            return LocalPipelineBaseSegment(
                segmentId: segment.segmentId,
                start: segment.start,
                end: segment.end,
                text: normalizedText,
                confidence: segment.confidence
            )
        }

        guard !cleaned.isEmpty else { return [] }

        var merged: [LocalPipelineBaseSegment] = []

        for segment in cleaned {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }

            let normalizedLast = normalizedText(last.text)
            let normalizedCurrent = normalizedText(segment.text)
            let gap = max(0, segment.start - last.end)
            let mergedDuration = segment.end - last.start
            let shouldMergeShortFragment =
                gap <= 0.25
                && mergedDuration <= 6.5
                && (
                    normalizedLast.count < 8
                    || normalizedCurrent.count < 6
                    || !endsSentence(last.text)
                )

            if normalizedLast == normalizedCurrent {
                merged[merged.count - 1] = LocalPipelineBaseSegment(
                    segmentId: last.segmentId,
                    start: min(last.start, segment.start),
                    end: max(last.end, segment.end),
                    text: last.text.count >= segment.text.count ? last.text : segment.text,
                    confidence: max(last.confidence, segment.confidence)
                )
                continue
            }

            if shouldMergeShortFragment {
                merged[merged.count - 1] = LocalPipelineBaseSegment(
                    segmentId: last.segmentId,
                    start: last.start,
                    end: max(last.end, segment.end),
                    text: joinLyricsFragments(last.text, segment.text),
                    confidence: max(last.confidence, segment.confidence)
                )
                continue
            }

            merged.append(segment)
        }

        return merged
    }

    private func normalizedReferenceGuideSegments(_ segments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
        segments.compactMap { segment in
            let normalizedText = normalizeLyricsText(segment.text)
            guard !normalizedText.isEmpty else { return nil }
            return LocalPipelineBaseSegment(
                segmentId: segment.segmentId,
                start: segment.start,
                end: segment.end,
                text: normalizedText,
                confidence: segment.confidence
            )
        }
    }

    private func normalizeLyricsText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "�", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func joinLyricsFragments(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        return left + right
    }

    private func shouldMergeOrSkipDuplicate(
        last: LocalPipelineBaseSegment,
        current: LocalPipelineBaseSegment
    ) -> Bool {
        let normalizedLast = normalizedText(last.text)
        let normalizedCurrent = normalizedText(current.text)
        guard !normalizedLast.isEmpty, !normalizedCurrent.isEmpty else {
            return false
        }

        let startDelta = abs(last.start - current.start)
        let endDelta = abs(last.end - current.end)
        let overlaps = current.start <= last.end + 0.35
        let containment = normalizedLast.contains(normalizedCurrent) || normalizedCurrent.contains(normalizedLast)
        let same = normalizedLast == normalizedCurrent
        let prefixLength = commonPrefixLength(normalizedLast, normalizedCurrent)
        let minLength = max(1, min(normalizedLast.count, normalizedCurrent.count))
        let prefixRatio = Double(prefixLength) / Double(minLength)

        return (same && (startDelta <= 1.0 || endDelta <= 1.0 || overlaps))
            || (containment && overlaps)
            || (overlaps && prefixRatio >= 0.7)
    }

    private func splitLongBaseSegment(_ segment: LocalPipelineBaseSegment) -> [LocalPipelineBaseSegment] {
        let normalized = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = segment.end - segment.start
        guard duration >= Self.preferredBaseSegmentDuration || normalized.count >= 12 else {
            return [segment]
        }

        guard let splitIndex = preferredSplitIndex(in: normalized) else {
            return [segment]
        }

        let firstText = String(normalized[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondText = String(normalized[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstText.isEmpty, !secondText.isEmpty else {
            return [segment]
        }

        let totalCount = max(firstText.count + secondText.count, 1)
        let ratio = Double(firstText.count) / Double(totalCount)
        let boundary = segment.start + ((segment.end - segment.start) * ratio)
        guard boundary > segment.start + 0.25, boundary < segment.end - 0.25 else {
            return [segment]
        }

        let first = LocalPipelineBaseSegment(
            segmentId: segment.segmentId + "-a",
            start: segment.start,
            end: boundary,
            text: firstText,
            confidence: segment.confidence
        )
        let second = LocalPipelineBaseSegment(
            segmentId: segment.segmentId + "-b",
            start: boundary,
            end: segment.end,
            text: secondText,
            confidence: segment.confidence
        )
        return splitLongBaseSegment(first) + splitLongBaseSegment(second)
    }

    private func preferredSplitIndex(in text: String) -> String.Index? {
        guard text.count >= 8 else { return nil }

        let midpoint = text.index(text.startIndex, offsetBy: text.count / 2)
        let splitCharacters = CharacterSet(charactersIn: "、。！？!?・ 　")

        let candidates = text.indices.filter { index in
            let scalar = text[index].unicodeScalars.first
            return scalar.map { splitCharacters.contains($0) } ?? false
        }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            text.distance(from: lhs, to: midpoint).magnitude < text.distance(from: rhs, to: midpoint).magnitude
        }.map { text.index(after: $0) }
    }

    private func isObviouslyGarbageTranscript(_ text: String, confidence: Double) -> Bool {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else { return true }

        let punctuationSet = CharacterSet(charactersIn: "・、。！？!?…ー-")
        let scalars = normalized.unicodeScalars
        if !scalars.isEmpty && scalars.allSatisfy({ punctuationSet.contains($0) }) {
            return true
        }

        if normalized.allSatisfy({ $0.isNumber }) {
            return true
        }

        if normalized.count == 2 {
            let filtered = normalized.replacingOccurrences(of: " ", with: "")
            if filtered.count == 2, Set(filtered).count == 1 {
                return true
            }
        }

        let latin = normalized.filter { $0.isASCII && $0.isLetter }
        if !latin.isEmpty && latin.count == normalized.count && normalized.count == 1 {
            return true
        }

        if !latin.isEmpty && latin.count == normalized.count && normalized.count <= 2 {
            return true
        }

        if confidence < 0.1 && normalized.count <= 2 {
            return true
        }

        return false
    }

    private func buildDraftSegments(
        textSegments: [LocalPipelineBaseSegment],
        timingGuideSegments: [LocalPipelineBaseSegment],
        lyricsReference: LocalLyricsReferenceInput?,
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double,
        logger: RunLogger,
        runId: String
    ) throws -> [LocalPipelineDraftSegment] {
        if let lyricsReference, !lyricsReference.isEmpty {
            let guideSegments = timingGuideSegments.isEmpty ? textSegments : timingGuideSegments
            return try buildDraftSegmentsFromReferenceLyrics(
                lyricsReference,
                guideSegments: guideSegments,
                normalizedAudioURL: normalizedAudioURL,
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate,
                logger: logger,
                runId: runId
            )
        }
        return buildDraftSegmentsFromTranscription(
            textSegments,
            timingGuideSegments: timingGuideSegments,
            totalDuration: Double(normalizedSamples.count) / sampleRate
        )
    }

    private func buildDraftSegmentsFromTranscription(
        _ segments: [LocalPipelineBaseSegment],
        timingGuideSegments: [LocalPipelineBaseSegment],
        totalDuration: TimeInterval
    ) -> [LocalPipelineDraftSegment] {
        var blocks: [LocalPipelineDraftSegment] = []
        var current: [LocalPipelineBaseSegment] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            let blockID = String(format: "block-%05d", blocks.count + 1)
            let text = current.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                current.removeAll()
                return
            }
            blocks.append(
                LocalPipelineDraftSegment(
                    segmentId: blockID,
                    chunkId: current.first?.segmentId.components(separatedBy: "-seg-").first ?? blockID,
                    startTime: current.first?.start ?? 0,
                    endTime: current.last?.end ?? 0,
                    text: text,
                    sourceSegmentIDs: current.map(\.segmentId)
                )
            )
            current.removeAll()
        }

        for segment in segments {
            if current.isEmpty {
                current.append(segment)
            } else if shouldStartNewDraftBlock(current: current, next: segment) {
                flushCurrent()
                current.append(segment)
            } else {
                current.append(segment)
            }

            let duration = (current.last?.end ?? segment.end) - (current.first?.start ?? segment.start)
            if current.count >= Self.draftMaxLines
                || duration >= Self.draftTargetDuration
                || (endsSentence(segment.text) && duration >= 2.0) {
                flushCurrent()
            }
        }

        flushCurrent()
        guard !blocks.isEmpty, !timingGuideSegments.isEmpty else {
            return blocks
        }

        let guideRegions = makeGuideRegions(from: timingGuideSegments, speechRegions: [])
        guard !guideRegions.isEmpty else {
            return blocks
        }

        let entries = blocks.enumerated().map { index, block in
            ReferenceLyricEntry(
                text: block.text,
                sourceStart: block.startTime,
                sourceEnd: block.endTime,
                sourceIndex: index
            )
        }
        let matches = alignReferenceEntries(entries, to: guideRegions)
        let retimed = blocks.enumerated().map { index, block in
            var retimedBlock = block
            let timing = referenceTiming(
                for: matches[index],
                index: index,
                matches: matches,
                coarseTiming: (block.startTime, block.endTime)
            )
            retimedBlock.startTime = timing.start
            retimedBlock.endTime = timing.end
            retimedBlock.sourceSegmentIDs = matches[index].region?.sourceSegmentIDs ?? block.sourceSegmentIDs
            retimedBlock.alignmentSearchStart = max(0, timing.start - Self.txtAlignmentPadding)
            retimedBlock.alignmentSearchEnd = min(totalDuration, timing.end + Self.txtAlignmentPadding)
            return retimedBlock
        }

        return enforceReferenceDraftOrder(retimed, totalDuration: totalDuration)
    }

    private func buildDraftSegmentsFromReferenceLyrics(
        _ lyricsReference: LocalLyricsReferenceInput,
        guideSegments: [LocalPipelineBaseSegment],
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double,
        logger: RunLogger,
        runId: String
    ) throws -> [LocalPipelineDraftSegment] {
        let entries = lyricsReference.entries.filter { !$0.text.isEmpty }
        guard !entries.isEmpty else { return [] }

        switch lyricsReference.sourceKind {
        case .srt where entries.allSatisfy({ $0.sourceStart != nil && $0.sourceEnd != nil }):
            return buildDraftSegmentsFromReferenceSRT(
                entries,
                guideSegments: guideSegments,
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate
            )
        case .plainText, .srt:
            return try buildDraftSegmentsFromReferenceText(
                entries,
                guideSegments: guideSegments,
                normalizedAudioURL: normalizedAudioURL,
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate,
                logger: logger,
                runId: runId
            )
        }
    }

    private func buildDraftSegmentsFromReferenceSRT(
        _ entries: [ReferenceLyricEntry],
        guideSegments: [LocalPipelineBaseSegment],
        normalizedSamples: [Float],
        sampleRate: Double
    ) -> [LocalPipelineDraftSegment] {
        let totalDuration = Double(normalizedSamples.count) / sampleRate

        return entries.enumerated().compactMap { index, entry in
            guard let sourceStart = entry.sourceStart else { return nil }
            let sourceEnd = max(entry.sourceEnd ?? (sourceStart + expectedDuration(for: entry.text)), sourceStart + 0.35)
            let corrected = gentlyCorrectSRTReferenceTiming(
                start: sourceStart,
                end: sourceEnd,
                totalDuration: totalDuration,
                samples: normalizedSamples,
                sampleRate: sampleRate
            )
            let sourceIDs = guideSegments
                .filter { $0.end >= corrected.start - 0.4 && $0.start <= corrected.end + 0.4 }
                .map(\.segmentId)

            return LocalPipelineDraftSegment(
                segmentId: String(format: "block-%05d", index + 1),
                chunkId: "lyrics-reference-srt",
                startTime: corrected.start,
                endTime: corrected.end,
                text: entry.text,
                sourceSegmentIDs: sourceIDs,
                referenceSourceKind: .srt,
                alignmentSearchStart: max(0, sourceStart - Self.referenceSRTSearchPad),
                alignmentSearchEnd: min(totalDuration, sourceEnd + Self.referenceSRTSearchPad)
            )
        }
    }

    private func buildDraftSegmentsFromReferenceText(
        _ entries: [ReferenceLyricEntry],
        guideSegments: [LocalPipelineBaseSegment],
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double,
        logger: RunLogger,
        runId: String
    ) throws -> [LocalPipelineDraftSegment] {
        let speechRegions =
            detectSpeechRegionsWithFFmpeg(audioURL: normalizedAudioURL, totalDuration: Double(normalizedSamples.count) / sampleRate)
            ?? detectSpeechRegions(samples: normalizedSamples, sampleRate: sampleRate)
        let totalDuration = Double(normalizedSamples.count) / sampleRate
        let timings: [(start: TimeInterval, end: TimeInterval)]
        if speechRegions.isEmpty {
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.chunking.rawValue,
                level: .warn,
                message: "reference lyrics VAD produced no speech regions; using coarse sequential timing",
                engineType: .localPipeline
            )
            timings = coarseSequentialReferenceTimings(
                for: entries,
                speechRegions: speechRegions,
                guideSegments: guideSegments,
                totalDuration: totalDuration
            )
        } else {
            timings = sequentialReferenceTimingsAcrossSpeechRegions(
                texts: entries.map(\.text),
                speechRegions: speechRegions,
                totalDuration: totalDuration
            )
        }

        let draftSegments = entries.enumerated().map { index, entry in
            let timing = timings[index]
            return LocalPipelineDraftSegment(
                segmentId: String(format: "block-%05d", index + 1),
                chunkId: "lyrics-reference-text",
                startTime: timing.start,
                endTime: timing.end,
                text: entry.text,
                sourceSegmentIDs: [],
                referenceSourceKind: .plainText,
                alignmentSearchStart: max(0, timing.start - Self.txtAlignmentPadding),
                alignmentSearchEnd: min(totalDuration, timing.end + Self.txtAlignmentPadding)
            )
        }
        let orderedDraftSegments = enforceReferenceDraftOrder(
            draftSegments,
            totalDuration: totalDuration
        )

        return orderedDraftSegments
    }

    private func detectSpeechRegionsWithFFmpeg(
        audioURL: URL,
        totalDuration: TimeInterval
    ) -> [SpeechRegion]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg",
            "-i", audioURL.path,
            "-af", "silencedetect=noise=-32dB:d=0.25",
            "-f", "null",
            "-"
        ]
        process.environment = buildProcessEnvironment(extraExecutableURLs: [])

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let stderrText = String(data: stderrData, encoding: .utf8) else {
            return nil
        }

        let silenceStarts = regexCaptureValues(in: stderrText, pattern: #"silence_start:\s*([0-9.]+)"#).compactMap(Double.init)
        let silenceEnds = regexCaptureValues(in: stderrText, pattern: #"silence_end:\s*([0-9.]+)"#).compactMap(Double.init)
        guard !silenceStarts.isEmpty, silenceStarts.count == silenceEnds.count else {
            return nil
        }

        var speechRegions: [SpeechRegion] = []
        var cursor: TimeInterval = 0
        for (silenceStart, silenceEnd) in zip(silenceStarts, silenceEnds) {
            if silenceStart > cursor + Self.vadMinRegionDuration {
                speechRegions.append(SpeechRegion(start: cursor, end: silenceStart))
            }
            cursor = max(cursor, silenceEnd)
        }
        if totalDuration > cursor + Self.vadMinRegionDuration {
            speechRegions.append(SpeechRegion(start: cursor, end: totalDuration))
        }

        return mergeSpeechRegions(
            speechRegions.filter { $0.end - $0.start >= Self.vadMinRegionDuration }
        )
    }

    private func sequentialReferenceTimingsAcrossSpeechRegions(
        texts: [String],
        speechRegions: [SpeechRegion],
        totalDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !texts.isEmpty else { return [] }
        guard !speechRegions.isEmpty else {
            return distributedReferenceTimings(
                texts: texts,
                spanStart: 0,
                spanEnd: totalDuration,
                totalDuration: totalDuration
            )
        }

        let totalSpeechDuration = speechRegions.reduce(0) { $0 + max(0, $1.end - $1.start) }
        guard totalSpeechDuration > 0.01 else {
            return distributedReferenceTimings(
                texts: texts,
                spanStart: speechRegions.first?.start ?? 0,
                spanEnd: speechRegions.last?.end ?? totalDuration,
                totalDuration: totalDuration
            )
        }

        let weights = texts.map(expectedDuration(for:))
        let totalWeight = max(weights.reduce(0, +), 0.001)
        var cumulativeSpeech: [TimeInterval] = [0]
        cumulativeSpeech.reserveCapacity(speechRegions.count + 1)
        for region in speechRegions {
            cumulativeSpeech.append(cumulativeSpeech.last! + max(0, region.end - region.start))
        }

        func speechRegionIndex(for offset: TimeInterval) -> Int {
            let clampedOffset = clamp(offset, min: 0, max: totalSpeechDuration)
            for index in speechRegions.indices {
                let regionEndOffset = cumulativeSpeech[index + 1]
                if clampedOffset <= regionEndOffset || index == speechRegions.count - 1 {
                    return index
                }
            }
            return max(0, speechRegions.count - 1)
        }

        var lineIndexesByRegion = Array(repeating: [Int](), count: speechRegions.count)
        var consumedWeight: TimeInterval = 0
        for (index, weight) in weights.enumerated() {
            let midpointWeight = consumedWeight + (weight / 2)
            let midpointOffset = totalSpeechDuration * (midpointWeight / totalWeight)
            let regionIndex = speechRegionIndex(for: midpointOffset)
            lineIndexesByRegion[regionIndex].append(index)
            consumedWeight += weight
        }

        var timings = Array(repeating: (start: 0.0, end: 0.0), count: texts.count)

        for (regionIndex, lineIndexes) in lineIndexesByRegion.enumerated() {
            guard !lineIndexes.isEmpty else { continue }
            let region = speechRegions[regionIndex]
            let localTexts = lineIndexes.map { texts[$0] }
            let localTimings = distributedReferenceTimings(
                texts: localTexts,
                spanStart: region.start,
                spanEnd: region.end,
                totalDuration: totalDuration
            )
            for (localIndex, lineIndex) in lineIndexes.enumerated() {
                timings[lineIndex] = localTimings[localIndex]
            }
        }

        return timings.enumerated().map { index, timing in
            let nextStart = index + 1 < timings.count ? timings[index + 1].start : nil
            let safeEnd = nextStart.map { min(timing.end, $0) } ?? timing.end
            return (timing.start, max(timing.start + Self.minimumStandaloneSubtitleDuration, safeEnd))
        }
    }

    private func gentlyCorrectSRTReferenceTiming(
        start: TimeInterval,
        end: TimeInterval,
        totalDuration: TimeInterval,
        samples: [Float],
        sampleRate: Double
    ) -> (start: TimeInterval, end: TimeInterval) {
        let searchStart = max(0, start - Self.referenceSRTSearchPad)
        let searchEnd = min(totalDuration, end + Self.referenceSRTSearchPad)
        let searchSamples = extractSamples(from: samples, sampleRate: sampleRate, start: searchStart, end: searchEnd)
        guard !searchSamples.isEmpty else { return (start, end) }

        let windowSize = max(1, Int(sampleRate * Self.vadWindowSize))
        let leading = firstActiveWindow(in: searchSamples, windowSize: windowSize)
        let trailing = lastActiveWindow(in: searchSamples, windowSize: windowSize)
        guard let leading, let trailing, trailing > leading else { return (start, end) }

        let candidateStart = searchStart + max(0, Double(leading - windowSize / 2) / sampleRate)
        let candidateEnd = searchStart + min(Double(searchSamples.count), Double(trailing + windowSize / 2)) / sampleRate
        let boundedStart = clamp(candidateStart, min: max(0, start - Self.referenceSRTMaxShift), max: min(totalDuration, start + Self.referenceSRTMaxShift))
        let boundedEnd = clamp(candidateEnd, min: max(0, end - Self.referenceSRTMaxShift), max: min(totalDuration, end + Self.referenceSRTMaxShift))
        guard boundedEnd > boundedStart else { return (start, end) }
        return (boundedStart, max(boundedStart + 0.35, boundedEnd))
    }

    private func detectSpeechRegions(samples: [Float], sampleRate: Double) -> [SpeechRegion] {
        guard !samples.isEmpty else { return [] }
        let windowSize = max(1, Int(sampleRate * Self.vadWindowSize))
        var profile: [(rms: Float, peak: Float)] = []
        profile.reserveCapacity(max(1, samples.count / windowSize))

        for index in stride(from: 0, to: samples.count, by: windowSize) {
            let end = min(index + windowSize, samples.count)
            let window = samples[index..<end]
            let peak = window.map { abs($0) }.max() ?? 0
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            profile.append((rms, peak))
        }

        let rmsValues = profile.map(\.rms)
        guard let maxRMS = rmsValues.max(), maxRMS >= Self.localWaveformAlignmentConfig.minVolumeAbsolute else { return [] }
        let threshold = calculateAdaptiveThreshold(rmsValues)
        var active = profile.map { $0.peak >= 0.015 || $0.rms >= threshold }
        fillShortGaps(&active, maxGapFrames: max(1, Int(Self.vadMinGapFill / Self.vadWindowSize)))

        var regions: [SpeechRegion] = []
        var regionStart: Int?
        for index in active.indices {
            if active[index] {
                regionStart = regionStart ?? index
            } else if let currentRegionStart = regionStart {
                let region = makeSpeechRegion(startIndex: currentRegionStart, endIndex: index, windowSize: windowSize, sampleRate: sampleRate)
                if region.end - region.start >= Self.vadMinRegionDuration {
                    regions.append(region)
                }
                regionStart = nil
            }
        }

        if let currentRegionStart = regionStart {
            let region = makeSpeechRegion(startIndex: currentRegionStart, endIndex: active.count, windowSize: windowSize, sampleRate: sampleRate)
            if region.end - region.start >= Self.vadMinRegionDuration {
                regions.append(region)
            }
        }

        return mergeSpeechRegions(regions)
    }

    private func makeGuideRegions(
        from guideSegments: [LocalPipelineBaseSegment],
        speechRegions: [SpeechRegion]
    ) -> [GuideRegion] {
        guard !guideSegments.isEmpty else { return [] }
        return makeTimingGuideAnchors(from: guideSegments, speechRegions: speechRegions).map { anchor in
            return GuideRegion(
                start: anchor.start,
                end: anchor.end,
                text: anchor.text,
                sourceSegmentIDs: anchor.sourceSegmentIDs
            )
        }
    }

    private func makeTimingGuideAnchors(
        from guideSegments: [LocalPipelineBaseSegment],
        speechRegions: [SpeechRegion]
    ) -> [TimingGuideAnchor] {
        guideSegments.compactMap { segment in
            let trimmed = trimmedTimingGuideRange(for: segment, speechRegions: speechRegions)
            guard trimmed.end > trimmed.start + 0.02 else { return nil }
            return TimingGuideAnchor(
                start: trimmed.start,
                end: trimmed.end,
                text: segment.text,
                confidence: segment.confidence,
                sourceSegmentIDs: [segment.segmentId]
            )
        }
    }

    private func trimmedTimingGuideRange(
        for segment: LocalPipelineBaseSegment,
        speechRegions: [SpeechRegion]
    ) -> (start: TimeInterval, end: TimeInterval) {
        guard !speechRegions.isEmpty else {
            return (segment.start, segment.end)
        }

        let overlapping = speechRegions.filter { region in
            region.end >= segment.start - 0.2 && region.start <= segment.end + 0.2
        }
        guard !overlapping.isEmpty else {
            return (segment.start, segment.end)
        }

        let start = max(segment.start, overlapping.map(\.start).min() ?? segment.start)
        let end = min(segment.end, overlapping.map(\.end).max() ?? segment.end)
        guard end > start + 0.02 else {
            return (segment.start, segment.end)
        }
        return (start, end)
    }

    private func alignReferenceEntries(
        _ entries: [ReferenceLyricEntry],
        to guideRegions: [GuideRegion]
    ) -> [ReferenceAlignmentMatch] {
        let lineCount = entries.count
        let regionCount = guideRegions.count
        guard lineCount > 0 else { return [] }

        var states = Array(
            repeating: Array<AlignmentState?>(repeating: nil, count: regionCount + 1),
            count: lineCount + 1
        )
        var backtrack = Array(
            repeating: Array<(previousI: Int, previousJ: Int, matchedRegionCount: Int, unmatched: Bool)?>(repeating: nil, count: regionCount + 1),
            count: lineCount + 1
        )
        states[0][0] = AlignmentState(cost: 0, lastMatchedEnd: nil)

        func updateState(
            i: Int,
            j: Int,
            cost: Double,
            lastMatchedEnd: TimeInterval?,
            previousI: Int,
            previousJ: Int,
            matchedRegionCount: Int,
            unmatched: Bool
        ) {
            let candidate = AlignmentState(cost: cost, lastMatchedEnd: lastMatchedEnd)
            if let existing = states[i][j], existing.cost <= candidate.cost {
                return
            }
            states[i][j] = candidate
            backtrack[i][j] = (previousI, previousJ, matchedRegionCount, unmatched)
        }

        for i in 0...lineCount {
            for j in 0...regionCount {
                guard let state = states[i][j] else { continue }

                if j < regionCount {
                    updateState(
                        i: i,
                        j: j + 1,
                        cost: state.cost + Self.skippedRegionPenalty,
                        lastMatchedEnd: state.lastMatchedEnd,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 0,
                        unmatched: false
                    )
                }

                guard i < lineCount else { continue }

                updateState(
                    i: i + 1,
                    j: j,
                    cost: state.cost + Self.unmatchedLinePenalty,
                    lastMatchedEnd: state.lastMatchedEnd,
                    previousI: i,
                    previousJ: j,
                    matchedRegionCount: 0,
                    unmatched: true
                )

                if j < regionCount {
                    let region = guideRegions[j]
                    updateState(
                        i: i + 1,
                        j: j + 1,
                        cost: state.cost + costToMatch(entry: entries[i], region: region, previousEnd: state.lastMatchedEnd),
                        lastMatchedEnd: region.end,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 1,
                        unmatched: false
                    )
                }

                if j + 1 < regionCount {
                    let combined = combineGuideRegions(guideRegions[j], guideRegions[j + 1])
                    updateState(
                        i: i + 1,
                        j: j + 2,
                        cost: state.cost + costToMatch(entry: entries[i], region: combined, previousEnd: state.lastMatchedEnd),
                        lastMatchedEnd: combined.end,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 2,
                        unmatched: false
                    )
                }

                if j + 2 < regionCount {
                    let combined = combineGuideRegions(
                        combineGuideRegions(guideRegions[j], guideRegions[j + 1]),
                        guideRegions[j + 2]
                    )
                    updateState(
                        i: i + 1,
                        j: j + 3,
                        cost: state.cost + costToMatch(entry: entries[i], region: combined, previousEnd: state.lastMatchedEnd),
                        lastMatchedEnd: combined.end,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 3,
                        unmatched: false
                    )
                }
            }
        }

        let bestEndIndex = (0...regionCount)
            .compactMap { index in states[lineCount][index].map { (index, $0.cost) } }
            .min(by: { $0.1 < $1.1 })?
            .0 ?? 0

        var matches = Array<ReferenceAlignmentMatch?>(repeating: nil, count: lineCount)
        var i = lineCount
        var j = bestEndIndex

        while i > 0 {
            guard let step = backtrack[i][j] else {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: nil, wasUnmatched: true)
                i -= 1
                continue
            }

            if step.unmatched {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: nil, wasUnmatched: true)
            } else if step.matchedRegionCount == 1 {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: guideRegions[step.previousJ], wasUnmatched: false)
            } else if step.matchedRegionCount == 2 {
                matches[i - 1] = ReferenceAlignmentMatch(
                    entry: entries[i - 1],
                    region: combineGuideRegions(guideRegions[step.previousJ], guideRegions[step.previousJ + 1]),
                    wasUnmatched: false
                )
            } else if step.matchedRegionCount == 3 {
                matches[i - 1] = ReferenceAlignmentMatch(
                    entry: entries[i - 1],
                    region: combineGuideRegions(
                        combineGuideRegions(guideRegions[step.previousJ], guideRegions[step.previousJ + 1]),
                        guideRegions[step.previousJ + 2]
                    ),
                    wasUnmatched: false
                )
            } else {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: nil, wasUnmatched: true)
            }

            i = step.previousI
            j = step.previousJ
        }

        return matches.compactMap { $0 }
    }

    private func referenceTiming(
        for match: ReferenceAlignmentMatch,
        index: Int,
        matches: [ReferenceAlignmentMatch],
        coarseTiming: (start: TimeInterval, end: TimeInterval)
    ) -> (start: TimeInterval, end: TimeInterval) {
        if let region = match.region {
            return (region.start, max(region.end, region.start + Self.minimumStandaloneSubtitleDuration))
        }

        let previousMatched = matches[..<index].reversed().first(where: { $0.region != nil })?.region
        let nextMatched = matches.dropFirst(index + 1).first(where: { $0.region != nil })?.region

        if let previousMatched, let nextMatched,
           let fitted = fitReferenceTiming(
               preferredStart: coarseTiming.start,
               preferredDuration: coarseTiming.end - coarseTiming.start,
               minStart: previousMatched.end + 0.08,
               maxEnd: nextMatched.start - 0.08
           ) {
            return fitted
        }

        if let nextMatched,
           let fitted = fitReferenceTiming(
               preferredStart: coarseTiming.start,
               preferredDuration: coarseTiming.end - coarseTiming.start,
               minStart: max(0, nextMatched.start - max(coarseTiming.end - coarseTiming.start, Self.minimumStandaloneSubtitleDuration) - 0.08),
               maxEnd: nextMatched.start - 0.08
           ) {
            return fitted
        }

        if let previousMatched,
           let fitted = fitReferenceTiming(
               preferredStart: max(coarseTiming.start, previousMatched.end + 0.08),
               preferredDuration: coarseTiming.end - coarseTiming.start,
               minStart: previousMatched.end + 0.08,
               maxEnd: max(previousMatched.end + Self.minimumStandaloneSubtitleDuration, coarseTiming.end)
           ) {
            return fitted
        }

        return coarseTiming
    }

    private func fitReferenceTiming(
        preferredStart: TimeInterval,
        preferredDuration: TimeInterval,
        minStart: TimeInterval,
        maxEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let minimumDuration = Self.minimumStandaloneSubtitleDuration
        guard maxEnd - minStart >= minimumDuration else { return nil }

        let duration = max(minimumDuration, preferredDuration)
        let start = min(max(preferredStart, minStart), maxEnd - minimumDuration)
        let end = min(maxEnd, max(start + minimumDuration, start + duration))
        guard end > start else { return nil }
        return (start, end)
    }

    private func sanitizeAlignedSegments(
        _ segments: [LocalPipelineAlignedSegment],
        draftSegmentsByID: [String: LocalPipelineDraftSegment],
        orderedDraftSegments: [LocalPipelineDraftSegment]
    ) -> [LocalPipelineAlignedSegment] {
        let alignedByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.segmentId, $0) })
        var filtered: [LocalPipelineAlignedSegment] = []

        for draft in orderedDraftSegments {
            guard let aligned = alignedByID[draft.segmentId], aligned.end > aligned.start else { continue }

            if draft.referenceSourceKind == .srt {
                let maxShift = Self.referenceSRTMaxShift
                guard abs(aligned.start - draft.startTime) <= maxShift,
                      abs(aligned.end - draft.endTime) <= maxShift else {
                    continue
                }
            } else {
                let searchStart = draft.alignmentSearchStart ?? max(0, draft.startTime - Self.aeneasMaxShift)
                let searchEnd = draft.alignmentSearchEnd ?? (draft.endTime + Self.aeneasMaxShift)
                guard aligned.start >= searchStart,
                      aligned.end <= searchEnd else {
                    continue
                }
            }

            if let previousEnd = filtered.last?.end, aligned.start < previousEnd {
                continue
            }

            if aligned.end - aligned.start < Self.minimumStandaloneSubtitleDuration {
                continue
            }

            filtered.append(aligned)
        }

        return filtered
    }

    private func coarseSequentialReferenceTimings(
        for entries: [ReferenceLyricEntry],
        speechRegions: [SpeechRegion],
        guideSegments: [LocalPipelineBaseSegment],
        totalDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let spanStart: TimeInterval
        let spanEnd: TimeInterval

        if let firstSpeech = speechRegions.first, let lastSpeech = speechRegions.last {
            spanStart = firstSpeech.start
            spanEnd = lastSpeech.end
        } else if let firstGuide = guideSegments.map(\.start).min(),
                  let lastGuide = guideSegments.map(\.end).max() {
            spanStart = firstGuide
            spanEnd = lastGuide
        } else {
            spanStart = 0
            spanEnd = totalDuration
        }

        return distributedReferenceTimings(
            texts: entries.map(\.text),
            spanStart: spanStart,
            spanEnd: spanEnd,
            totalDuration: totalDuration
        )
    }

    private func distributedReferenceTimings(
        texts: [String],
        spanStart: TimeInterval,
        spanEnd: TimeInterval,
        totalDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !texts.isEmpty else { return [] }

        let minimumDuration = Self.minimumStandaloneSubtitleDuration
        let minimumTotalDuration = Double(texts.count) * minimumDuration
        var start = max(0, spanStart)
        var end = min(totalDuration, max(spanEnd, start + minimumTotalDuration))

        if end - start < minimumTotalDuration {
            start = max(0, min(start, totalDuration - minimumTotalDuration))
            end = min(totalDuration, max(start + minimumTotalDuration, spanEnd))
        }
        if end - start < minimumTotalDuration {
            start = 0
            end = max(totalDuration, minimumTotalDuration)
        }

        let weights = texts.map(expectedDuration(for:))
        let totalWeight = max(weights.reduce(0, +), 0.001)
        var cursor = start
        var timings: [(start: TimeInterval, end: TimeInterval)] = []
        timings.reserveCapacity(texts.count)

        for (index, weight) in weights.enumerated() {
            let remainingMinimum = Double(texts.count - index - 1) * minimumDuration
            let remainingWindow = max(minimumDuration, end - cursor - remainingMinimum)
            let proposedDuration = max(minimumDuration, (end - start) * (weight / totalWeight))
            let duration = min(proposedDuration, remainingWindow)
            let segmentEnd = index == texts.count - 1 ? end : min(end, cursor + duration)
            timings.append((cursor, max(cursor + minimumDuration, segmentEnd)))
            cursor = max(cursor + minimumDuration, segmentEnd)
        }

        if let lastIndex = timings.indices.last {
            timings[lastIndex].end = max(timings[lastIndex].start + minimumDuration, end)
        }

        return timings.enumerated().map { index, timing in
            let nextStart = index + 1 < timings.count ? timings[index + 1].start : nil
            let safeEnd = nextStart.map { min(timing.end, $0) } ?? timing.end
            return (timing.start, max(timing.start + minimumDuration, safeEnd))
        }
    }

    private func enforceReferenceDraftOrder(
        _ segments: [LocalPipelineDraftSegment],
        totalDuration: TimeInterval
    ) -> [LocalPipelineDraftSegment] {
        guard !segments.isEmpty else { return [] }

        var ordered: [LocalPipelineDraftSegment] = []
        ordered.reserveCapacity(segments.count)

        for segment in segments {
            var adjusted = segment
            let duration = max(Self.minimumStandaloneSubtitleDuration, segment.endTime - segment.startTime)
            let minimumStart = ordered.last.map(\.endTime) ?? 0
            adjusted.startTime = max(adjusted.startTime, minimumStart)
            adjusted.endTime = adjusted.startTime + duration

            if adjusted.endTime > totalDuration {
                adjusted.endTime = max(adjusted.startTime + Self.minimumStandaloneSubtitleDuration, totalDuration)
            }

            if adjusted.endTime <= adjusted.startTime {
                adjusted.endTime = adjusted.startTime + Self.minimumStandaloneSubtitleDuration
            }

            adjusted.alignmentSearchStart = max(0, adjusted.startTime - Self.txtAlignmentPadding)
            adjusted.alignmentSearchEnd = min(totalDuration, adjusted.endTime + Self.txtAlignmentPadding)
            ordered.append(adjusted)
        }

        return ordered
    }

    private func combineGuideRegions(_ lhs: GuideRegion, _ rhs: GuideRegion) -> GuideRegion {
        GuideRegion(
            start: min(lhs.start, rhs.start),
            end: max(lhs.end, rhs.end),
            text: joinSubtitleTexts(lhs.text, rhs.text),
            sourceSegmentIDs: lhs.sourceSegmentIDs + rhs.sourceSegmentIDs
        )
    }

    private func costToMatch(
        entry: ReferenceLyricEntry,
        region: GuideRegion,
        previousEnd: TimeInterval?
    ) -> Double {
        let similarity = longestCommonSubsequenceRatio(normalizedText(entry.text), normalizedText(region.text))
        let similarityCost = (1 - similarity) * 4.0
        let expected = expectedDuration(for: entry.text)
        let durationCost = abs((region.end - region.start) - expected) / max(expected, 0.8)
        let gapCost: Double
        if let previousEnd {
            let gap = max(0, region.start - previousEnd)
            gapCost = gap > 1.8 ? (gap - 1.8) * 0.35 : gap * 0.08
        } else {
            gapCost = max(0, region.start - 0.2) * 0.04
        }
        return similarityCost + durationCost + gapCost
    }

    private func expectedDuration(for text: String) -> TimeInterval {
        clamp(Double(max(normalizedText(text).count, 1)) * 0.22, min: 0.8, max: 6.0)
    }

    private func calculateAdaptiveThreshold(_ rmsValues: [Float]) -> Float {
        guard !rmsValues.isEmpty else { return Self.localWaveformAlignmentConfig.minVolumeAbsolute }
        let sorted = rmsValues.sorted()
        let noiseFloor = sorted[Int(Float(sorted.count - 1) * 0.1)]
        let speechPeak = sorted[Int(Float(sorted.count - 1) * 0.9)]
        return max((noiseFloor + speechPeak) / 2, Self.localWaveformAlignmentConfig.minVolumeAbsolute)
    }

    private func fillShortGaps(_ active: inout [Bool], maxGapFrames: Int) {
        var gapStart: Int?
        for index in active.indices {
            if !active[index] {
                gapStart = gapStart ?? index
            } else if let currentGapStart = gapStart, index - currentGapStart <= maxGapFrames, currentGapStart > 0, active[currentGapStart - 1] {
                for fillIndex in currentGapStart..<index {
                    active[fillIndex] = true
                }
                gapStart = nil
            } else {
                gapStart = nil
            }
        }
    }

    private func clearGap(_ gapStart: inout Int?) {
        gapStart = nil
    }

    private func makeSpeechRegion(
        startIndex: Int,
        endIndex: Int,
        windowSize: Int,
        sampleRate: Double
    ) -> SpeechRegion {
        SpeechRegion(
            start: Double(startIndex * windowSize) / sampleRate,
            end: Double(endIndex * windowSize) / sampleRate
        )
    }

    private func mergeSpeechRegions(_ regions: [SpeechRegion]) -> [SpeechRegion] {
        guard !regions.isEmpty else { return [] }
        var merged: [SpeechRegion] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            guard let last = merged.last else {
                merged.append(region)
                continue
            }
            if region.start - last.end <= Self.vadMergeGap {
                merged[merged.count - 1] = SpeechRegion(start: last.start, end: max(last.end, region.end))
            } else {
                merged.append(region)
            }
        }
        return merged
    }

    private func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.max(minimum, Swift.min(maximum, value))
    }

    private func longestCommonSubsequenceRatio(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var previous = Array(repeating: 0, count: right.count + 1)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftCharacter in left {
            for (index, rightCharacter) in right.enumerated() {
                if leftCharacter == rightCharacter {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(current[index], previous[index + 1])
                }
            }
            swap(&previous, &current)
            current = Array(repeating: 0, count: right.count + 1)
        }

        return Double(previous[right.count]) / Double(min(left.count, right.count))
    }

    private func regexCaptureValues(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }

    private func shouldStartNewDraftBlock(
        current: [LocalPipelineBaseSegment],
        next: LocalPipelineBaseSegment
    ) -> Bool {
        guard let first = current.first, let last = current.last else { return false }
        let durationWithNext = next.end - first.start
        let gap = next.start - last.end
        if current.count >= Self.draftMaxLines {
            return true
        }
        if durationWithNext > Self.draftMaxDuration {
            return true
        }
        if gap > 1.2 {
            return true
        }
        if endsSentence(last.text) && normalizedText(next.text).count >= 4 {
            return true
        }
        return false
    }

    private func runAlignment(
        runId: String,
        sourceFileName: String,
        draftSegments: [LocalPipelineDraftSegment],
        normalizedSamples: [Float],
        sampleRate: Double,
        layout: RunDirectoryLayout,
        settings: LocalPipelineSettings,
        allowsReferenceFallback: Bool,
        resolvedPaths: ResolvedPaths,
        logger: RunLogger,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> [LocalPipelineAlignedSegment] {
        guard !draftSegments.isEmpty else { return [] }

        let inputSegments = try draftSegments.map { segment in
            let clipStart = max(0, segment.alignmentSearchStart ?? (segment.startTime - Self.alignmentPadding))
            let clipEnd = max(clipStart + 0.2, segment.alignmentSearchEnd ?? (segment.endTime + Self.alignmentPadding))
            let clipURL = layout.alignmentInputDirectoryURL.appendingPathComponent("\(segment.segmentId).wav")
            let clipSamples = extractSamples(
                from: normalizedSamples,
                sampleRate: sampleRate,
                start: clipStart,
                end: clipEnd
            )
            try writePCM16WAV(samples: clipSamples, sampleRate: sampleRate, to: clipURL)
            return AlignmentInputSegment(
                segmentId: segment.segmentId,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text,
                audioPath: clipURL.path,
                clipStartTime: clipStart
            )
        }

        let inputManifest = AlignmentInputManifest(
            runId: runId,
            sourceFileName: sourceFileName,
            language: settings.language,
            segments: inputSegments
        )
        let manifestURL = layout.alignmentInputDirectoryURL.appendingPathComponent("segments.json")
        let outputJSONURL = layout.alignmentInputDirectoryURL.appendingPathComponent("segment_alignment.json")
        try writeJSON(inputManifest, to: manifestURL)
        let draftSegmentsByID = Dictionary(uniqueKeysWithValues: draftSegments.map { ($0.segmentId, $0) })

        let tracker = AlignmentProgressTracker(totalBlocks: inputSegments.count, progress: progress)
        let request = ExternalProcessRequest(
            executablePath: resolvedPaths.pythonExecutableURL.path,
            arguments: buildAeneasArguments(
                scriptURL: resolvedPaths.aeneasScriptURL,
                inputAudioURL: layout.inputDirectoryURL.appendingPathComponent("normalized.wav"),
                segmentsJSONURL: manifestURL,
                language: settings.language,
                outputJSONURL: outputJSONURL
            ),
            workingDirectory: layout.rootURL,
            environment: buildProcessEnvironment(extraExecutableURLs: [resolvedPaths.pythonExecutableURL]),
            timeout: max(240, Double(inputSegments.count) * Self.alignmentTimeoutPerBlock),
            onStderrChunk: { data in
                await tracker.consume(data)
            }
        )
        let command = renderCommandLine(executablePath: request.executablePath, arguments: request.arguments)
        let result: ExternalProcessResult
        do {
            result = try await processRunner.run(request)
        } catch let error as ExternalProcessRunnerError {
            switch error {
            case let .timedOut(_, timeout, stdout, stderr):
                try appendTimedOutProcessOutput(
                    stdout: stdout,
                    stderr: stderr,
                    to: layout.aeneasStderrURL,
                    header: "==== aeneas ====\n"
                )
                if allowsReferenceFallback {
                    try logger.log(
                        runId: runId,
                        stage: LocalPipelinePhase.aligning.rawValue,
                        level: .warn,
                        message: "aeneas timed out after \(timeout)s; using draft timing fallback",
                        engineType: .localPipeline,
                        command: command,
                        stderrPath: layout.aeneasStderrURL
                    )
                    return []
                }
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.aligning.rawValue,
                    level: .error,
                    message: "aeneas timed out after \(timeout)s",
                    engineType: .localPipeline,
                    command: command,
                    stderrPath: layout.aeneasStderrURL
                )
                throw LocalPipelineError.alignmentFailed(readStdErr(layout.aeneasStderrURL) ?? "aeneas timed out after \(timeout)s")
            default:
                throw error
            }
        }

        try appendStderr(result.stderr, to: layout.aeneasStderrURL, header: "==== aeneas ====\n")

        guard result.exitCode == 0 else {
            if allowsReferenceFallback {
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.aligning.rawValue,
                    level: .warn,
                    message: "aeneas failed; using draft timing fallback",
                    engineType: .localPipeline,
                    command: command,
                    exitCode: result.exitCode,
                    stderrPath: layout.aeneasStderrURL
                )
                return []
            }
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .error,
                message: "aeneas failed",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
            throw LocalPipelineError.alignmentFailed(readStdErr(layout.aeneasStderrURL) ?? "aeneas exited with code \(result.exitCode)")
        }

        let outputData = try readJSONData(
            fallbackURL: outputJSONURL,
            stdout: result.stdout,
            failureMessage: "aeneas did not produce JSON output"
        )
        let output = try decodeAlignmentOutput(from: outputData)
        guard !output.segments.isEmpty else {
            if allowsReferenceFallback {
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.aligning.rawValue,
                    level: .warn,
                    message: "aeneas produced no aligned blocks; using reference timing fallback",
                    engineType: .localPipeline,
                    command: command,
                    exitCode: result.exitCode,
                    stderrPath: layout.aeneasStderrURL
                )
                return []
            }
            let details = buildAlignmentFailureMessage(stderrURL: layout.aeneasStderrURL)
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .error,
                message: "aeneas produced no aligned blocks",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
            throw LocalPipelineError.alignmentFailed(details)
        }
        try logger.log(
            runId: runId,
            stage: LocalPipelinePhase.aligning.rawValue,
            level: .info,
            message: "aeneas aligned blocks",
            engineType: .localPipeline,
            command: command,
            exitCode: result.exitCode,
            stderrPath: layout.aeneasStderrURL
        )
        let filteredSegments = sanitizeAlignedSegments(
            output.segments,
            draftSegmentsByID: draftSegmentsByID,
            orderedDraftSegments: draftSegments
        )

        if filteredSegments.isEmpty, allowsReferenceFallback {
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .warn,
                message: "aeneas aligned blocks fell outside reference guard window; using fallback timing",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
            return []
        }

        if filteredSegments.count != output.segments.count {
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .warn,
                message: "discarded \(output.segments.count - filteredSegments.count) misaligned block(s)",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
        }

        return filteredSegments
    }

    private func makeChunkPlans(
        samples: [Float],
        sampleRate: Double,
        chunkLengthSeconds: Double,
        overlapSeconds: Double
    ) throws -> [LocalPipelineChunkPlan] {
        let chunkSampleCount = max(1, Int(sampleRate * chunkLengthSeconds))
        let overlapSampleCount = max(0, Int(sampleRate * overlapSeconds))
        let step = max(1, chunkSampleCount - overlapSampleCount)
        var plans: [LocalPipelineChunkPlan] = []
        var startSample = 0
        var index = 0

        while startSample < samples.count {
            let endSample = min(startSample + chunkSampleCount, samples.count)
            let start = Double(startSample) / sampleRate
            let end = Double(endSample) / sampleRate
            index += 1
            let chunkId = String(format: "chunk-%05d", index)
            plans.append(LocalPipelineChunkPlan(chunkId: chunkId, start: start, end: end))
            if endSample >= samples.count {
                break
            }
            startSample += step
        }

        return plans
    }

    private func buildWhisperArguments(
        modelURL: URL,
        audioURL: URL,
        outputPrefix: URL,
        language: String,
        initialPrompt: String,
        temperature: Double,
        beamSize: Int,
        noSpeechThreshold: Double,
        logprobThreshold: Double
    ) -> [String] {
        var arguments = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-l", language,
            "-tp", String(format: "%.3f", temperature),
            "-bs", String(beamSize),
            "-nth", String(format: "%.3f", noSpeechThreshold),
            "-lpt", String(format: "%.3f", logprobThreshold),
            "-nf",
            "-ojf",
            "-of", outputPrefix.path
        ]
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", prompt])
        }
        return arguments
    }

    private func buildAeneasArguments(
        scriptURL: URL,
        inputAudioURL: URL,
        segmentsJSONURL: URL,
        language: String,
        outputJSONURL: URL
    ) -> [String] {
        [
            scriptURL.path,
            "--input-audio", inputAudioURL.path,
            "--segments-json", segmentsJSONURL.path,
            "--language", language,
            "--output-json", outputJSONURL.path
        ]
    }

    private func buildWhisperPrompt(userPrompt: String) -> String {
        let basePrompt = Self.whisperBasePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserPrompt.isEmpty else { return basePrompt }
        return basePrompt + "\n" + trimmedUserPrompt
    }

    private func whisperDecodingSettings(
        from settings: LocalPipelineSettings,
        purpose: LocalWhisperDecodingPurpose,
        noSpeechThreshold: Double? = nil
    ) -> LocalWhisperDecodingSettings {
        LocalWhisperDecodingSettings(
            baseModel: settings.baseModel,
            language: settings.language,
            initialPrompt: buildWhisperPrompt(userPrompt: settings.initialPrompt),
            temperature: settings.temperature,
            beamSize: settings.beamSize,
            noSpeechThreshold: noSpeechThreshold ?? settings.noSpeechThreshold,
            logprobThreshold: settings.logprobThreshold,
            purpose: purpose
        )
    }

    private func wrapWhisperError(_ error: Error) -> LocalPipelineError {
        if let pipelineError = error as? LocalPipelineError {
            return pipelineError
        }
        return LocalPipelineError.baseTranscriptionFailed(error.localizedDescription)
    }

    private func parseWhisperOutput(
        from data: Data,
        plan: LocalPipelineChunkPlan,
        settings: LocalPipelineSettings
    ) throws -> LocalPipelineBaseChunkOutput {
        let sanitizedData = normalizeJSONDataForDecoding(data)
        let payload = try JSONSerialization.jsonObject(with: sanitizedData)
        let rawSegments = extractRawSegments(from: payload)
        var segments: [LocalPipelineBaseSegment] = []
        segments.reserveCapacity(rawSegments.count)

        for (index, raw) in rawSegments.enumerated() {
            let confidence = extractConfidence(raw)
            if let tokenSegments = makeTokenSegments(from: raw, plan: plan, confidence: confidence, fallbackIndex: index + 1),
               !tokenSegments.isEmpty {
                segments.append(contentsOf: tokenSegments)
                continue
            }
            guard let range = extractSegmentRange(raw) else {
                continue
            }
            let start = plan.start + min(range.start, range.end)
            let end = plan.start + max(range.start, range.end)
            let text = extractString(raw, keys: ["text", "transcript", "content"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            segments.append(
                LocalPipelineBaseSegment(
                    segmentId: "\(plan.chunkId)-seg-\(String(format: "%04d", index + 1))",
                    start: start,
                    end: end,
                    text: text,
                    confidence: confidence
                )
            )
        }

        let resolvedSegments: [LocalPipelineBaseSegment]
        if segments.isEmpty {
            let text = extractString(payload, keys: ["text", "transcript", "content"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            resolvedSegments = [
                LocalPipelineBaseSegment(
                    segmentId: "\(plan.chunkId)-seg-0001",
                    start: plan.start,
                    end: plan.end,
                    text: text,
                    confidence: extractConfidence(payload)
                )
            ]
        } else {
            resolvedSegments = segments
        }

        return LocalPipelineBaseChunkOutput(
            chunkId: plan.chunkId,
            engineType: SRTGenerationEngine.localPipeline.rawValue,
            baseModel: settings.baseModel.rawValue,
            language: settings.language,
            segments: mergeTouchingShortSegments(mergeRawBaseSegments(resolvedSegments))
        )
    }

    private func makeTokenSegments(
        from raw: Any,
        plan: LocalPipelineChunkPlan,
        confidence: Double,
        fallbackIndex: Int
    ) -> [LocalPipelineBaseSegment]? {
        let pieces = extractTokenPieces(from: raw, plan: plan, confidence: confidence)
        guard pieces.count >= 2 else { return nil }

        var groups: [[WhisperTokenPiece]] = []
        var current: [WhisperTokenPiece] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            groups.append(current)
            current.removeAll()
        }

        for piece in pieces {
            guard !piece.text.isEmpty else { continue }
            if current.isEmpty {
                current.append(piece)
                continue
            }

            let currentText = current.map(\.text).joined()
            let currentLength = normalizedText(currentText).count
            let nextLength = currentLength + normalizedText(piece.text).count
            let gap = max(0, piece.start - (current.last?.end ?? piece.start))
            let durationWithNext = piece.end - (current.first?.start ?? piece.start)

            let shouldBreak =
                (gap >= Self.tokenSegmentStrongGap && currentLength >= 2)
                || (gap >= Self.tokenSegmentSoftGap && currentLength >= Self.tokenSegmentTargetCharacters)
                || nextLength > Self.tokenSegmentMaxCharacters
                || durationWithNext > Self.tokenSegmentHardMaxDuration
                || endsSentence(currentText)

            if shouldBreak {
                flushCurrent()
            }
            current.append(piece)
        }

        flushCurrent()

        let collapsed = collapseTinyTokenGroups(groups)
        let segments = collapsed.enumerated().compactMap { offset, group -> LocalPipelineBaseSegment? in
            guard let first = group.first, let last = group.last else { return nil }
            let text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LocalPipelineBaseSegment(
                segmentId: "\(plan.chunkId)-seg-\(String(format: "%04d", fallbackIndex + offset))",
                start: first.start,
                end: max(last.end, first.start + 0.08),
                text: text,
                confidence: group.map(\.confidence).max() ?? confidence
            )
        }

        guard segments.count > 1 else { return nil }
        return segments
    }

    private func extractTokenPieces(
        from raw: Any,
        plan: LocalPipelineChunkPlan,
        confidence: Double
    ) -> [WhisperTokenPiece] {
        guard let dictionary = raw as? [String: Any],
              let tokens = dictionary["tokens"] as? [Any] else {
            return []
        }

        var pieces: [WhisperTokenPiece] = []
        pieces.reserveCapacity(tokens.count)

        for token in tokens {
            let text = extractString(token, keys: ["text", "token", "content"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let normalized = normalizedText(text)
            guard !normalized.isEmpty else { continue }
            if text.hasPrefix("[_"), text.hasSuffix("]") {
                continue
            }
            guard let range = extractSegmentRange(token) else { continue }
            let start = plan.start + min(range.start, range.end)
            let end = plan.start + max(range.start, range.end)
            pieces.append(
                WhisperTokenPiece(
                    start: start,
                    end: max(end, start + 0.05),
                    text: text,
                    confidence: confidence
                )
            )
        }

        return pieces
    }

    private func collapseTinyTokenGroups(_ groups: [[WhisperTokenPiece]]) -> [[WhisperTokenPiece]] {
        guard !groups.isEmpty else { return [] }
        var collapsed: [[WhisperTokenPiece]] = []

        for group in groups {
            let groupText = group.map(\.text).joined()
            let groupLength = normalizedText(groupText).count
            if groupLength <= 1, !collapsed.isEmpty {
                collapsed[collapsed.count - 1].append(contentsOf: group)
            } else {
                collapsed.append(group)
            }
        }

        if collapsed.count >= 2 {
            for index in stride(from: collapsed.count - 1, through: 1, by: -1) {
                let text = collapsed[index].map(\.text).joined()
                if normalizedText(text).count <= 1 {
                    collapsed[index - 1].append(contentsOf: collapsed[index])
                    collapsed.remove(at: index)
                }
            }
        }

        return collapsed
    }

    private func mergeTouchingShortSegments(_ segments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [LocalPipelineBaseSegment] = []

        for segment in segments {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }

            let lastLength = normalizedText(last.text).count
            let currentLength = normalizedText(segment.text).count
            let gap = segment.start - last.end

            if gap <= 0.18 && (lastLength <= 1 || currentLength <= 1) {
                merged[merged.count - 1] = LocalPipelineBaseSegment(
                    segmentId: last.segmentId,
                    start: min(last.start, segment.start),
                    end: max(last.end, segment.end),
                    text: last.text + segment.text,
                    confidence: max(last.confidence, segment.confidence)
                )
                continue
            }

            merged.append(segment)
        }

        return merged
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            count += 1
        }
        return count
    }

    private func decodeAlignmentOutput(from data: Data) throws -> LocalPipelineSegmentAlignmentOutput {
        do {
            return try JSONDecoder().decode(LocalPipelineSegmentAlignmentOutput.self, from: data)
        } catch {
            throw LocalPipelineError.invalidJSON("Invalid aeneas JSON: \(error.localizedDescription)")
        }
    }

    private func normalizeJSONDataForDecoding(_ data: Data) -> Data {
        if String(data: data, encoding: .utf8) != nil {
            return data
        }
        return Data(String(decoding: data, as: UTF8.self).utf8)
    }

    private func extractRawSegments(from payload: Any) -> [Any] {
        if let dictionary = payload as? [String: Any] {
            if let segments = dictionary["segments"] as? [Any] {
                return segments
            }
            if let transcription = dictionary["transcription"] as? [Any], !transcription.isEmpty {
                return transcription
            }
        }
        if let array = payload as? [Any] {
            return array
        }
        return []
    }

    private func extractSegmentRange(_ payload: Any) -> (start: Double, end: Double)? {
        if let start = extractDouble(payload, keys: ["start", "start_time", "offset"]),
           let end = extractDouble(payload, keys: ["end", "end_time", "duration"]) {
            return (start, end)
        }

        guard let dictionary = payload as? [String: Any] else {
            return nil
        }

        if let offsets = dictionary["offsets"] as? [String: Any],
           let startMilliseconds = extractDouble(offsets, keys: ["from", "start"]),
           let endMilliseconds = extractDouble(offsets, keys: ["to", "end"]) {
            return (startMilliseconds / 1000, endMilliseconds / 1000)
        }

        if let timestamps = dictionary["timestamps"] as? [String: Any],
           let startText = extractString(timestamps, keys: ["from", "start"]),
           let endText = extractString(timestamps, keys: ["to", "end"]),
           let startSeconds = parseWhisperTimestamp(startText),
           let endSeconds = parseWhisperTimestamp(endText) {
            return (startSeconds, endSeconds)
        }

        return nil
    }

    private func parseWhisperTimestamp(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let hours = Double(parts[0]), let minutes = Double(parts[1]) else {
            return nil
        }

        let secondsParts = parts[2].split(separator: ",")
        guard secondsParts.count == 2,
              let seconds = Double(secondsParts[0]),
              let milliseconds = Double(secondsParts[1]) else {
            return nil
        }

        return (hours * 3600) + (minutes * 60) + seconds + (milliseconds / 1000)
    }

    private func extractString(_ payload: Any, keys: [String]) -> String? {
        guard let dictionary = payload as? [String: Any] else { return nil }
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func extractDouble(_ payload: Any, keys: [String]) -> Double? {
        guard let dictionary = payload as? [String: Any] else { return nil }
        for key in keys {
            if let value = dictionary[key] as? Double {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = dictionary[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }
        return nil
    }

    private func extractConfidence(_ payload: Any) -> Double {
        guard let dictionary = payload as? [String: Any] else { return 0.75 }
        if let confidence = extractDouble(dictionary, keys: ["confidence", "score", "probability"]) {
            return clamp(confidence, min: 0, max: 1)
        }
        let avgLogProb = extractDouble(dictionary, keys: ["avg_logprob", "avgLogProb", "logprob"])
        let noSpeechProb = extractDouble(dictionary, keys: ["no_speech_prob", "noSpeechProb"])
        var confidence = 0.75
        if let avgLogProb {
            confidence = clamp(1 + (avgLogProb / 5), min: 0, max: 1)
        }
        if let noSpeechProb {
            confidence *= clamp(1 - noSpeechProb, min: 0, max: 1)
        }
        return clamp(confidence, min: 0, max: 1)
    }

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "。.!！？?♪".contains(last)
    }

    private func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
    }

    private func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }

    private func extractSamples(from samples: [Float], sampleRate: Double, start: TimeInterval, end: TimeInterval) -> [Float] {
        let lower = max(0, Int((start * sampleRate).rounded(.down)))
        let upper = min(samples.count, Int((end * sampleRate).rounded(.up)))
        guard upper > lower else { return [] }
        return Array(samples[lower..<upper])
    }

    private func writePCM16WAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let channelCount = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let byteRate = Int(sampleRate) * channelCount * bytesPerSample
        let blockAlign = channelCount * bytesPerSample

        var pcm = Data(capacity: samples.count * bytesPerSample)
        for sample in samples {
            let clipped = Swift.max(-1, Swift.min(1, sample))
            var pcmSample = Int16((clipped * 32_767).rounded()).littleEndian
            withUnsafeBytes(of: &pcmSample) { pcm.append(contentsOf: $0) }
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
        wav.append(littleEndianBytes(UInt16(channelCount)))
        wav.append(littleEndianBytes(UInt32(Int(sampleRate.rounded()))))
        wav.append(littleEndianBytes(UInt32(byteRate)))
        wav.append(littleEndianBytes(UInt16(blockAlign)))
        wav.append(littleEndianBytes(UInt16(bitsPerSample)))
        wav.append(Data("data".utf8))
        wav.append(littleEndianBytes(UInt32(dataChunkSize)))
        wav.append(pcm)

        try wav.write(to: url, options: [.atomic])
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try jsonEncoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func writeText(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func buildProcessEnvironment(extraExecutableURLs: [URL]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let defaultPaths = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let inheritedPaths = (inherited["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let extraPaths = extraExecutableURLs.map { $0.deletingLastPathComponent().path }

        var orderedPaths: [String] = []
        var seen = Set<String>()
        for path in extraPaths + inheritedPaths + defaultPaths {
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            orderedPaths.append(path)
        }

        var environment: [String: String] = [
            "PATH": orderedPaths.joined(separator: ":")
        ]
        if let home = inherited["HOME"], !home.isEmpty {
            environment["HOME"] = home
        }
        if let temp = inherited["TMPDIR"], !temp.isEmpty {
            environment["TMPDIR"] = temp
        }
        return environment
    }

    private func readJSONData(fallbackURL: URL, stdout: Data, failureMessage: String) throws -> Data {
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return try Data(contentsOf: fallbackURL)
        }
        guard !stdout.isEmpty else {
            throw LocalPipelineError.invalidJSON(failureMessage)
        }
        return stdout
    }

    private func cleanupSuccessfulRunArtifacts(layout: RunDirectoryLayout) throws {
        let fileManager = FileManager.default
        let removableDirectories = [
            layout.inputDirectoryURL,
            layout.chunksDirectoryURL,
            layout.alignmentInputDirectoryURL
        ]

        for directoryURL in removableDirectories where fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
    }

    private func buildAlignmentFailureMessage(stderrURL: URL) -> String {
        guard let stderrText = readStdErr(stderrURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !stderrText.isEmpty else {
            return "aeneas did not align any subtitle blocks."
        }

        if stderrText.contains("[WARN]") || stderrText.contains("[ERROR]") {
            return stderrText
        }

        return "aeneas did not align any subtitle blocks."
    }

    private func refineSubtitlesForWaveform(
        _ subtitles: [SubtitleItem],
        fallbackSubtitles: [SubtitleItem],
        hasReferenceLyrics: Bool,
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double
    ) async throws -> [SubtitleItem] {
        _ = normalizedAudioURL
        let fallbackItems = fallbackSubtitles.isEmpty ? subtitles : fallbackSubtitles
        let trimmed = zip(subtitles, fallbackItems).map { subtitle, fallback -> SubtitleItem in
            let adjusted = trimSubtitleToSpeech(subtitle, samples: normalizedSamples, sampleRate: sampleRate)
            if hasReferenceLyrics && isSilentSubtitle(adjusted, samples: normalizedSamples, sampleRate: sampleRate) {
                return fallback
            }
            return adjusted
        }

        if hasReferenceLyrics {
            return trimmed.filter { !isObviouslyGarbageTranscript($0.text, confidence: 0.75) }
        }

        let filtered = trimmed.filter {
            !isObviouslyGarbageTranscript($0.text, confidence: 0.75)
                && !isSilentSubtitle($0, samples: normalizedSamples, sampleRate: sampleRate)
        }
        return mergeTinySubtitles(filtered, minimumDuration: Self.minimumStandaloneSubtitleDuration)
    }

    private func mergeTinySubtitles(
        _ subtitles: [SubtitleItem],
        minimumDuration: TimeInterval
    ) -> [SubtitleItem] {
        guard subtitles.count >= 2 else { return subtitles }

        var merged = subtitles.sorted { $0.startTime < $1.startTime }
        var index = 0

        while index < merged.count {
            let duration = merged[index].endTime - merged[index].startTime
            guard duration <= minimumDuration else {
                index += 1
                continue
            }

            if index == 0 {
                merged[1] = SubtitleItem(
                    id: merged[1].id,
                    startTime: merged[index].startTime,
                    endTime: merged[1].endTime,
                    text: joinSubtitleTexts(merged[index].text, merged[1].text)
                )
                merged.remove(at: index)
                continue
            }

            let previousGap = max(0, merged[index].startTime - merged[index - 1].endTime)
            let nextGap = index + 1 < merged.count
                ? max(0, merged[index + 1].startTime - merged[index].endTime)
                : .greatestFiniteMagnitude

            if previousGap <= nextGap || index + 1 >= merged.count {
                merged[index - 1] = SubtitleItem(
                    id: merged[index - 1].id,
                    startTime: merged[index - 1].startTime,
                    endTime: max(merged[index - 1].endTime, merged[index].endTime),
                    text: joinSubtitleTexts(merged[index - 1].text, merged[index].text)
                )
                merged.remove(at: index)
                index = max(0, index - 1)
            } else {
                merged[index + 1] = SubtitleItem(
                    id: merged[index + 1].id,
                    startTime: merged[index].startTime,
                    endTime: merged[index + 1].endTime,
                    text: joinSubtitleTexts(merged[index].text, merged[index + 1].text)
                )
                merged.remove(at: index)
            }
        }

        return merged
    }

    private func joinSubtitleTexts(_ lhs: String, _ rhs: String) -> String {
        let trimmedLeft = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeft.isEmpty else { return trimmedRight }
        guard !trimmedRight.isEmpty else { return trimmedLeft }
        return trimmedLeft + "\n" + trimmedRight
    }

    private func isSilentSubtitle(_ subtitle: SubtitleItem, samples: [Float], sampleRate: Double) -> Bool {
        let segmentSamples = extractSamples(from: samples, sampleRate: sampleRate, start: subtitle.startTime, end: subtitle.endTime)
        guard !segmentSamples.isEmpty else { return true }

        let peak = segmentSamples.map { abs($0) }.max() ?? 0
        let rms = sqrt(segmentSamples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(segmentSamples.count))
        return peak < 0.02 && rms < 0.004
    }

    private func trimSubtitleToSpeech(_ subtitle: SubtitleItem, samples: [Float], sampleRate: Double) -> SubtitleItem {
        let segmentSamples = extractSamples(from: samples, sampleRate: sampleRate, start: subtitle.startTime, end: subtitle.endTime)
        guard !segmentSamples.isEmpty else { return subtitle }

        let windowSize = max(1, Int(sampleRate * 0.01))
        let leading = firstActiveWindow(in: segmentSamples, windowSize: windowSize)
        let trailing = lastActiveWindow(in: segmentSamples, windowSize: windowSize)
        guard let leading, let trailing, trailing > leading else { return subtitle }

        var trimmed = subtitle
        let paddedStart = max(0, Double(max(0, leading - windowSize / 2)) / sampleRate)
        let paddedEnd = Double(min(segmentSamples.count, trailing + windowSize / 2)) / sampleRate
        let newStart = subtitle.startTime + paddedStart
        let newEnd = subtitle.startTime + paddedEnd

        if newStart > subtitle.startTime + 0.04 {
            trimmed.startTime = min(newStart, subtitle.endTime - 0.12)
        }
        if newEnd < subtitle.endTime - 0.04 {
            trimmed.endTime = max(trimmed.startTime + 0.12, newEnd)
        }

        return trimmed
    }

    private func firstActiveWindow(in samples: [Float], windowSize: Int) -> Int? {
        guard samples.count >= windowSize else { return samples.firstIndex { abs($0) >= 0.015 } }
        for index in 0...(samples.count - windowSize) {
            let window = samples[index..<(index + windowSize)]
            let peak = window.map { abs($0) }.max() ?? 0
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            if peak >= 0.015 || rms >= 0.003 {
                return index
            }
        }
        return nil
    }

    private func lastActiveWindow(in samples: [Float], windowSize: Int) -> Int? {
        guard samples.count >= windowSize else {
            return samples.lastIndex { abs($0) >= 0.015 }
        }
        for index in stride(from: samples.count - windowSize, through: 0, by: -1) {
            let window = samples[index..<(index + windowSize)]
            let peak = window.map { abs($0) }.max() ?? 0
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            if peak >= 0.015 || rms >= 0.003 {
                return index + windowSize
            }
        }
        return nil
    }

    private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    private func appendStderr(_ data: Data, to url: URL, header: String) throws {
        try appendText(header, to: url)
        if !data.isEmpty {
            try appendData(data, to: url)
            try appendText("\n", to: url)
        }
    }

    private func appendTimedOutProcessOutput(
        stdout: Data,
        stderr: Data,
        to url: URL,
        header: String
    ) throws {
        if !stdout.isEmpty {
            try appendStderr(stdout, to: url, header: header + "[stdout]\n")
        }
        if !stderr.isEmpty {
            try appendStderr(stderr, to: url, header: header + "[stderr]\n")
        }
    }

    private func appendText(_ value: String, to url: URL) throws {
        guard let data = value.data(using: .utf8) else { return }
        try appendData(data, to: url)
    }

    private func appendData(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private func readStdErr(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func resolveReadableFile(_ rawPath: String, label: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalPipelineError.invalidConfiguration("Missing \(label).")
        }
        let candidates = runtimePathResolver.candidateURLs(forResourcePath: trimmed)
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return url
        }
        throw LocalPipelineError.missingModelFile(formatMissingCandidates(candidates))
    }

    private func resolveWhisperModel(settings: LocalPipelineSettings) throws -> URL {
        let trimmed = settings.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return try resolveReadableFile(trimmed, label: "whisper model")
        }

        let candidates = runtimePathResolver.candidateWhisperModelURLs(for: settings.baseModel)
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return url
        }

        throw LocalPipelineError.invalidConfiguration(
            """
            Missing whisper model.
            Expected one of:
            \(formatMissingCandidates(candidates))
            """
        )
    }

    private func resolveExecutable(_ rawPath: String, label: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalPipelineError.invalidConfiguration("Missing \(label).")
        }
        let candidates = runtimePathResolver.candidateExecutableURLs(for: trimmed)
        if let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return url
        }
        throw LocalPipelineError.missingExecutable(formatMissingCandidates(candidates))
    }

    private func formatMissingCandidates(_ candidates: [URL]) -> String {
        candidates.map(\.path).joined(separator: "\n")
    }

    private func prepareRuntimePaths(_ resolvedPaths: ResolvedPaths, layout: RunDirectoryLayout) throws -> ResolvedPaths {
        guard let coreMLURL = resolvedPaths.whisperCoreMLModelURL else {
            return resolvedPaths
        }

        let modelsDirectoryURL = layout.inputDirectoryURL.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)

        let runtimeModelURL = modelsDirectoryURL.appendingPathComponent(resolvedPaths.whisperModelURL.lastPathComponent)
        try createSymlinkIfNeeded(at: runtimeModelURL, destinationURL: resolvedPaths.whisperModelURL)

        let runtimeCoreMLURL = modelsDirectoryURL.appendingPathComponent(expectedCoreMLDirectoryName(for: resolvedPaths.whisperModelURL))
        try createSymlinkIfNeeded(at: runtimeCoreMLURL, destinationURL: coreMLURL)

        var runtimePaths = resolvedPaths
        runtimePaths.whisperModelURL = runtimeModelURL
        runtimePaths.whisperCoreMLModelURL = runtimeCoreMLURL
        return runtimePaths
    }

    private func expectedCoreMLDirectoryName(for whisperModelURL: URL) -> String {
        "\(whisperModelURL.deletingPathExtension().lastPathComponent)-encoder.mlmodelc"
    }

    private func createSymlinkIfNeeded(at url: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destinationURL)
    }

    private func reportProgress(
        _ progress: @escaping @Sendable (LocalPipelineProgress) async -> Void,
        phase: LocalPipelinePhase,
        message: String,
        currentChunk: Int,
        totalChunks: Int,
        displayPercent: Double
    ) async {
        await progress(
            LocalPipelineProgress(
                phase: phase,
                message: message,
                currentChunk: currentChunk,
                totalChunks: totalChunks,
                displayPercent: displayPercent
            )
        )
    }

    private func renderCommandLine(executablePath: String, arguments: [String]) -> String {
        ([executablePath] + arguments).map { component in
            if component.contains(where: \.isWhitespace) {
                return "\"\(component)\""
            }
            return component
        }
        .joined(separator: " ")
    }
}
