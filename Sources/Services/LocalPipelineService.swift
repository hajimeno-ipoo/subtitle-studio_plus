@preconcurrency import AVFoundation
import Foundation

final class LocalPipelineService: LocalPipelineAnalyzing, @unchecked Sendable {
    let processRunner: any ExternalProcessRunning
    private let whisperTranscriberBuilder: any LocalWhisperTranscriberBuilding
    private let runDirectoryBuilder: RunDirectoryBuilder
    private let correctionService: LocalPipelineCorrectionService
    private let assembler: LocalPipelineAssembler
    private let runtimePathResolver: AppRuntimePathResolver
    private let waveformService = WaveformService()
    let jsonEncoder: JSONEncoder

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
        var normalizedSamples = normalized.samples
        let normalizedSampleRate = normalized.sampleRate
        let normalizedURL = layout.inputDirectoryURL.appendingPathComponent("normalized.wav")
        try writePCM16WAV(samples: normalizedSamples, sampleRate: normalizedSampleRate, to: normalizedURL)
        try runDirectoryBuilder.markStage(.normalized, manifest: &manifest, at: layout.manifestURL)
        try logger.log(
            runId: manifest.runId,
            stage: "normalize",
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
            samples: normalizedSamples,
            sampleRate: normalizedSampleRate,
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

        var mergedTextSegments: [LocalPipelineBaseSegment] = []
        var timingGuideSegments: [LocalPipelineBaseSegment] = []

        if lyricsReference == nil {
            let textChunkResults = try await runBaseTranscription(
                runId: manifest.runId,
                plans: chunkPlans,
                normalizedSamples: normalizedSamples,
                sampleRate: normalizedSampleRate,
                layout: layout,
                decodingSettings: whisperDecodingSettings(
                    from: settings,
                    purpose: .lyricsText,
                    includeTimestamps: true
                ),
                whisperTranscriber: whisperTranscriber,
                logger: logger,
                displayStartPercent: 20,
                displayPercentSpan: 20,
                progress: progress
            )
            mergedTextSegments = postprocessLyricsSegments(prepareDraftSourceSegments(from: textChunkResults))
            timingGuideSegments = prepareTimingGuideSegments(from: textChunkResults)
            if timingGuideSegments.isEmpty {
                let timingChunkResults = try await runBaseTranscription(
                    runId: manifest.runId,
                    plans: chunkPlans,
                    normalizedSamples: normalizedSamples,
                    sampleRate: normalizedSampleRate,
                    layout: layout,
                    decodingSettings: whisperDecodingSettings(from: settings, purpose: .timingGuide),
                    whisperTranscriber: whisperTranscriber,
                    logger: logger,
                    displayStartPercent: 40,
                    displayPercentSpan: 15,
                    progress: progress
                )
                timingGuideSegments = prepareTimingGuideSegments(from: timingChunkResults)
            }
        } else if usesReferenceSRTTiming {
            mergedTextSegments = []
            timingGuideSegments = []
        } else {
            // TXT参照時も timing guide を生成（speech region 検出補助用）
            mergedTextSegments = []
            let timingChunkResults = try await runBaseTranscription(
                runId: manifest.runId,
                plans: chunkPlans,
                normalizedSamples: normalizedSamples,
                sampleRate: normalizedSampleRate,
                layout: layout,
                decodingSettings: whisperDecodingSettings(from: settings, purpose: .timingGuide),
                whisperTranscriber: whisperTranscriber,
                logger: logger,
                displayStartPercent: 40,
                displayPercentSpan: 15,
                progress: progress
            )
            timingGuideSegments = prepareTimingGuideSegments(from: timingChunkResults)
        }
        try runDirectoryBuilder.markStage(.baseTranscribed, manifest: &manifest, at: layout.manifestURL)
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

        var draftSegments = try buildDraftSegments(
            textSegments: mergedTextSegments,
            timingGuideSegments: timingGuideSegments,
            lyricsReference: lyricsReference,
            normalizedAudioURL: normalizedURL,
            normalizedSamples: normalizedSamples,
            sampleRate: normalizedSampleRate,
            logger: logger,
            runId: manifest.runId
        )
        mergedTextSegments.removeAll(keepingCapacity: false)
        timingGuideSegments.removeAll(keepingCapacity: false)
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

        var alignedSegments = try await runAlignment(
            runId: manifest.runId,
            sourceFileName: sourceFileName,
            draftSegments: draftSegments,
            normalizedSamples: normalizedSamples,
            sampleRate: normalizedSampleRate,
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
        draftSegments.removeAll(keepingCapacity: false)
        alignedSegments.removeAll(keepingCapacity: false)
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
            referenceSourceKind: lyricsReference?.sourceKind,
            normalizedAudioURL: normalizedURL,
            normalizedSamples: normalizedSamples,
            sampleRate: normalizedSampleRate
        )
        normalizedSamples.removeAll(keepingCapacity: false)
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

        if !LocalPipelineServiceConfig.preserveIntermediateArtifacts {
            try cleanupSuccessfulRunArtifacts(
                layout: layout,
                preserveAlignmentArtifacts: lyricsReference?.sourceKind == .plainText
            )
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

            let chunkSamples = extractSampleSlice(
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
        chunkSamples: ArraySlice<Float>,
        normalizedSamples: [Float],
        sampleRate: Double,
        layout: RunDirectoryLayout,
        decodingSettings: LocalWhisperDecodingSettings,
        whisperTranscriber: any LocalWhisperTranscribing,
        runId: String,
        logger: RunLogger
    ) async throws -> LocalPipelineBaseChunkOutput? {
        var retrySettings = decodingSettings
        retrySettings.noSpeechThreshold = min(decodingSettings.noSpeechThreshold, LocalPipelineServiceConfig.retryNoSpeechThreshold)
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
        let overlap = min(LocalPipelineServiceConfig.rescueChunkOverlapSeconds, max(0.1, (plan.end - plan.start) / 8))
        let stride = max(0.8, LocalPipelineServiceConfig.rescueChunkTargetDuration - overlap)
        var rescuePlans: [LocalPipelineChunkPlan] = []
        var cursor = plan.start
        var index = 1

        while cursor < plan.end - 0.2 {
            let end = min(plan.end, cursor + LocalPipelineServiceConfig.rescueChunkTargetDuration + overlap)
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
        rescueSettings.noSpeechThreshold = min(decodingSettings.noSpeechThreshold, LocalPipelineServiceConfig.retryNoSpeechThreshold)

        for rescuePlan in rescuePlans {
            let rescueChunkURL = layout.chunksDirectoryURL.appendingPathComponent("\(rescuePlan.chunkId).wav")
            let rescueChunkSamples = extractSampleSlice(
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

    func mergeRawBaseSegments(_ rawSegments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
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
        guard duration >= LocalPipelineServiceConfig.preferredBaseSegmentDuration || normalized.count >= 12 else {
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
}
