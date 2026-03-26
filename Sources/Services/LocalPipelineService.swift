@preconcurrency import AVFoundation
import Foundation

final class LocalPipelineService: LocalPipelineAnalyzing, @unchecked Sendable {
    private static let draftTargetDuration: TimeInterval = 6
    private static let draftMaxDuration: TimeInterval = 8
    private static let draftMaxLines = 1
    private static let alignmentPadding: TimeInterval = 0.15
    private static let alignmentTimeoutPerBlock: TimeInterval = 45
    private static let whisperBasePrompt = """
日本語の歌詞です。
自然な区切りの日本語の歌詞として認識してください。
歌詞らしい語順と自然な表記を優先してください。
"""

    private struct ResolvedPaths {
        var whisperCLIURL: URL
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
    private let runDirectoryBuilder: RunDirectoryBuilder
    private let correctionService: LocalPipelineCorrectionService
    private let assembler: LocalPipelineAssembler
    private let runtimePathResolver: AppRuntimePathResolver
    private let waveformService = WaveformService()
    private let jsonEncoder: JSONEncoder

    init(
        processRunner: any ExternalProcessRunning = ExternalProcessRunner(),
        runDirectoryBuilder: RunDirectoryBuilder = RunDirectoryBuilder(),
        correctionService: LocalPipelineCorrectionService = LocalPipelineCorrectionService(),
        assembler: LocalPipelineAssembler = LocalPipelineAssembler(),
        runtimePathResolver: AppRuntimePathResolver = AppRuntimePathResolver()
    ) {
        self.processRunner = processRunner
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

        let chunkResults = try await runBaseTranscription(
            runId: manifest.runId,
            plans: chunkPlans,
            normalizedSamples: normalized.samples,
            sampleRate: normalized.sampleRate,
            layout: layout,
            settings: settings,
            resolvedPaths: resolvedPaths,
            logger: logger,
            progress: progress
        )
        try runDirectoryBuilder.markStage(.baseTranscribed, manifest: &manifest, at: layout.manifestURL)

        let mergedSegments = mergeBaseSegments(from: chunkResults)
        guard !mergedSegments.isEmpty else {
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

        let draftSegments = buildDraftSegments(from: mergedSegments)
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
        let draftOutput = LocalPipelineDraftOutput(
            runId: manifest.runId,
            engineType: SRTGenerationEngine.localPipeline.rawValue,
            sourceFileName: sourceFileName,
            baseModel: settings.baseModel.rawValue,
            segments: draftSegments
        )
        try writeJSON(draftOutput, to: layout.draftJSONDirectoryURL.appendingPathComponent("draft_segments.json"))

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
            settings: settings
        )
        try runDirectoryBuilder.markStage(.corrected, manifest: &manifest, at: layout.manifestURL)

        let assembly = assembler.assemble(
            runId: manifest.runId,
            sourceFileName: sourceFileName,
            baseModel: settings.baseModel,
            correctedSegments: correctedSegments
        )
        guard !assembly.subtitles.isEmpty else {
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
        try writeText(SRTCodec.generateSRT(from: assembly.subtitles), to: finalSRTURL)
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

        try cleanupSuccessfulRunArtifacts(layout: layout)

        return LocalPipelineResult(
            subtitles: assembly.subtitles,
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

        let whisperCLIURL = try resolveExecutable(settings.whisperCLIPath, label: "whisper executable")
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
            whisperCLIURL: whisperCLIURL,
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
        settings: LocalPipelineSettings,
        resolvedPaths: ResolvedPaths,
        logger: RunLogger,
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
                displayPercent: 20 + (Double(index) / Double(max(plans.count, 1))) * 35
            )

            let chunkSamples = extractSamples(
                from: normalizedSamples,
                sampleRate: sampleRate,
                start: plan.start,
                end: plan.end
            )
            let chunkURL = layout.chunksDirectoryURL.appendingPathComponent("\(plan.chunkId).wav")
            try writePCM16WAV(samples: chunkSamples, sampleRate: sampleRate, to: chunkURL)

            let outputPrefix = layout.baseJSONDirectoryURL.appendingPathComponent(plan.chunkId)
            let outputJSONURL = outputPrefix.appendingPathExtension("json")
            let prompt = buildWhisperPrompt(userPrompt: settings.initialPrompt)
            let request = ExternalProcessRequest(
                executablePath: resolvedPaths.whisperCLIURL.path,
                arguments: buildWhisperArguments(
                    modelURL: resolvedPaths.whisperModelURL,
                    audioURL: chunkURL,
                    outputPrefix: outputPrefix,
                    language: settings.language,
                    initialPrompt: prompt,
                    temperature: settings.temperature,
                    beamSize: settings.beamSize,
                    noSpeechThreshold: settings.noSpeechThreshold,
                    logprobThreshold: settings.logprobThreshold
                ),
                workingDirectory: layout.rootURL,
                environment: buildProcessEnvironment(extraExecutableURLs: [resolvedPaths.whisperCLIURL]),
                timeout: 180
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
                        to: layout.whisperStderrURL,
                        header: "==== \(plan.chunkId) ====\n"
                    )
                    if let recoveredPayload = try? readJSONData(
                        fallbackURL: outputJSONURL,
                        stdout: stdout,
                        failureMessage: "whisper.cpp did not produce JSON output for \(plan.chunkId)"
                    ), let recoveredOutput = try? parseWhisperOutput(from: recoveredPayload, plan: plan, settings: settings) {
                        try writeJSON(recoveredOutput, to: outputJSONURL)
                        try logger.log(
                            runId: runId,
                            stage: LocalPipelinePhase.baseTranscribing.rawValue,
                            level: .warn,
                            message: "whisper.cpp timed out after \(timeout)s but recovered output",
                            engineType: .localPipeline,
                            chunkId: plan.chunkId,
                            command: command,
                            stderrPath: layout.whisperStderrURL
                        )
                        results.append((plan, recoveredOutput))
                        continue
                    }
                    try logger.log(
                        runId: runId,
                        stage: LocalPipelinePhase.baseTranscribing.rawValue,
                        level: .error,
                        message: "whisper.cpp timed out after \(timeout)s",
                        engineType: .localPipeline,
                        chunkId: plan.chunkId,
                        command: command,
                        stderrPath: layout.whisperStderrURL
                    )
                    throw LocalPipelineError.baseTranscriptionFailed(readStdErr(layout.whisperStderrURL) ?? "whisper.cpp timed out after \(timeout)s")
                default:
                    throw error
                }
            }

            try appendStderr(result.stderr, to: layout.whisperStderrURL, header: "==== \(plan.chunkId) ====\n")

            guard result.exitCode == 0 else {
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.baseTranscribing.rawValue,
                    level: .error,
                    message: "whisper.cpp failed",
                    engineType: .localPipeline,
                    chunkId: plan.chunkId,
                    command: command,
                    exitCode: result.exitCode,
                    stderrPath: layout.whisperStderrURL
                )
                throw LocalPipelineError.baseTranscriptionFailed(readStdErr(layout.whisperStderrURL) ?? "whisper.cpp exited with code \(result.exitCode)")
            }

            let payloadData = try readJSONData(
                fallbackURL: outputJSONURL,
                stdout: result.stdout,
                failureMessage: "whisper.cpp did not produce JSON output for \(plan.chunkId)"
            )
            let output = try parseWhisperOutput(from: payloadData, plan: plan, settings: settings)
            try writeJSON(output, to: outputJSONURL)
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.baseTranscribing.rawValue,
                level: .info,
                message: "chunk completed",
                engineType: .localPipeline,
                chunkId: plan.chunkId,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.whisperStderrURL
            )
            results.append((plan, output))
        }

        return results
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

    private func shouldMergeOrSkipDuplicate(
        last: LocalPipelineBaseSegment,
        current: LocalPipelineBaseSegment
    ) -> Bool {
        let normalizedLast = normalizedText(last.text)
        let normalizedCurrent = normalizedText(current.text)
        guard !normalizedLast.isEmpty, normalizedLast == normalizedCurrent else {
            return false
        }

        let startDelta = abs(last.start - current.start)
        let endDelta = abs(last.end - current.end)
        let overlaps = current.start <= last.end + 0.35
        return startDelta <= 1.0 || endDelta <= 1.0 || overlaps
    }

    private func buildDraftSegments(from segments: [LocalPipelineBaseSegment]) -> [LocalPipelineDraftSegment] {
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
            if current.count >= Self.draftMaxLines || duration >= Self.draftTargetDuration || endsSentence(segment.text) {
                flushCurrent()
            }
        }

        flushCurrent()
        return blocks
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
        if gap > 1.5 {
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
        resolvedPaths: ResolvedPaths,
        logger: RunLogger,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> [LocalPipelineAlignedSegment] {
        guard !draftSegments.isEmpty else { return [] }

        let inputSegments = try draftSegments.map { segment in
            let clipStart = max(0, segment.startTime - Self.alignmentPadding)
            let clipEnd = segment.endTime + Self.alignmentPadding
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
        let outputJSONURL = layout.alignedJSONDirectoryURL.appendingPathComponent("segment_alignment.json")
        try writeJSON(inputManifest, to: manifestURL)

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
        try writeJSON(output, to: outputJSONURL)
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
        return output.segments
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
            guard let range = extractSegmentRange(raw) else {
                continue
            }
            let start = plan.start + min(range.start, range.end)
            let end = plan.start + max(range.start, range.end)
            let text = extractString(raw, keys: ["text", "transcript", "content"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let confidence = extractConfidence(raw)
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
            segments: resolvedSegments
        )
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
            layout.baseJSONDirectoryURL,
            layout.draftJSONDirectoryURL,
            layout.alignmentInputDirectoryURL,
            layout.alignedJSONDirectoryURL
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
