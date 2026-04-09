import Foundation
import whisper

protocol LocalWhisperTranscriberBuilding: Sendable {
    func build(modelURL: URL) throws -> any LocalWhisperTranscribing
}

protocol LocalWhisperTranscribing: Sendable {
    func transcribe(
        plan: LocalPipelineChunkPlan,
        samples: ArraySlice<Float>,
        settings: LocalWhisperDecodingSettings
    ) throws -> LocalPipelineBaseChunkOutput

    var runtimeDiagnostics: [String] { get }
}

enum LocalWhisperDecodingPurpose: Sendable {
    case lyricsText
    case timingGuide
}

struct LocalWhisperDecodingSettings: Sendable {
    var baseModel: LocalBaseModel
    var language: String
    var initialPrompt: String
    var temperature: Double
    var beamSize: Int
    var noSpeechThreshold: Double
    var logprobThreshold: Double
    var purpose: LocalWhisperDecodingPurpose
}

struct WhisperSPMTranscriberBuilder: LocalWhisperTranscriberBuilding {
    func build(modelURL: URL) throws -> any LocalWhisperTranscribing {
        try WhisperSPMTranscriber(modelURL: modelURL)
    }
}

final class WhisperSPMTranscriber: LocalWhisperTranscribing, @unchecked Sendable {
    private static let timestampScale = 100.0
    private static let maxSegmentLength = 28
    private static let timingGuideMaxSegmentDuration: TimeInterval = 6.0
    private static let timingGuideMergeGap: TimeInterval = 0.16

    private struct RawSegment {
        var index: Int
        var text: String
        var confidence: Double
        var start: TimeInterval
        var end: TimeInterval
    }

    private let context: OpaquePointer
    private let runtimeDiagnosticsStorage: [String]

    init(modelURL: URL) throws {
        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        contextParams.flash_attn = false

        let expectedCoreMLURL = modelURL
            .deletingPathExtension()
            .appendingPathExtension("mlmodelc")
        let legacyCoreMLURL = modelURL
            .deletingPathExtension()
            .deletingLastPathComponent()
            .appendingPathComponent(modelURL.deletingPathExtension().lastPathComponent + "-encoder.mlmodelc", isDirectory: true)
        let detectedCoreMLURL = [legacyCoreMLURL, expectedCoreMLURL].first {
            FileManager.default.fileExists(atPath: $0.path)
        }

        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            throw LocalPipelineError.baseTranscriptionFailed("whisper.cpp のモデルを読み込めませんでした。")
        }

        self.context = context
        self.runtimeDiagnosticsStorage = [
            "model_path=\(modelURL.path)",
            "coreml_expected_path=\(legacyCoreMLURL.path)",
            detectedCoreMLURL.map { "coreml_detected_path=\($0.path)" } ?? "coreml_detected_path=none",
            "transcription_mode=lyrics_text_first",
            "use_gpu=\(contextParams.use_gpu)",
            "flash_attn=\(contextParams.flash_attn)"
        ]
    }

    deinit {
        whisper_free(context)
    }

    func transcribe(
        plan: LocalPipelineChunkPlan,
        samples: ArraySlice<Float>,
        settings: LocalWhisperDecodingSettings
    ) throws -> LocalPipelineBaseChunkOutput {
        guard !samples.isEmpty else {
            return LocalPipelineBaseChunkOutput(
                chunkId: plan.chunkId,
                engineType: SRTGenerationEngine.localPipeline.rawValue,
                baseModel: settings.baseModel.rawValue,
                language: settings.language,
                segments: []
            )
        }

        var params = whisper_full_default_params(settings.beamSize > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(recommendedThreadCount())
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.split_on_word = true
        params.max_len = Int32(Self.maxSegmentLength)
        params.max_tokens = 0
        params.temperature = Float(settings.temperature)
        params.logprob_thold = Float(settings.logprobThreshold)
        params.no_speech_thold = Float(settings.noSpeechThreshold)
        params.suppress_blank = true
        params.suppress_non_speech_tokens = true

        if settings.beamSize > 1 {
            params.beam_search.beam_size = Int32(settings.beamSize)
        } else {
            params.greedy.best_of = 1
        }

        switch settings.purpose {
        case .lyricsText:
            params.no_timestamps = true
            params.token_timestamps = false
        case .timingGuide:
            params.no_timestamps = false
            params.token_timestamps = true
        }

        let normalizedLanguage = normalizedLanguage(settings.language)
        let prompt = settings.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try withOptionalCString(normalizedLanguage) { languagePointer in
            params.language = languagePointer
            params.detect_language = languagePointer == nil

            return try withOptionalCString(prompt) { promptPointer in
                params.initial_prompt = promptPointer

                let whisperResult: Int32
                if let contiguousResult = try samples.withContiguousStorageIfAvailable({ buffer throws -> Int32 in
                    guard let baseAddress = buffer.baseAddress else {
                        throw LocalPipelineError.baseTranscriptionFailed("whisper.cpp に渡す音声データが空でした。")
                    }
                    return whisper_full(context, params, baseAddress, Int32(buffer.count))
                }) {
                    whisperResult = contiguousResult
                } else {
                    let contiguousSamples = Array(samples)
                    whisperResult = try contiguousSamples.withUnsafeBufferPointer { buffer in
                        guard let baseAddress = buffer.baseAddress else {
                            throw LocalPipelineError.baseTranscriptionFailed("whisper.cpp に渡す音声データが空でした。")
                        }
                        return whisper_full(context, params, baseAddress, Int32(buffer.count))
                    }
                }
                return whisperResult
            }
        }

        guard result == 0 else {
            throw LocalPipelineError.baseTranscriptionFailed("whisper.cpp の解析に失敗しました。")
        }

        return LocalPipelineBaseChunkOutput(
            chunkId: plan.chunkId,
            engineType: SRTGenerationEngine.localPipeline.rawValue,
            baseModel: settings.baseModel.rawValue,
            language: settings.language,
            segments: collectSegments(plan: plan, purpose: settings.purpose)
        )
    }

    var runtimeDiagnostics: [String] {
        runtimeDiagnosticsStorage
    }

    private func collectSegments(
        plan: LocalPipelineChunkPlan,
        purpose: LocalWhisperDecodingPurpose
    ) -> [LocalPipelineBaseSegment] {
        let segmentCount = Int(whisper_full_n_segments(context))
        guard segmentCount > 0 else { return [] }

        var rawSegments: [RawSegment] = []
        rawSegments.reserveCapacity(segmentCount)

        for segmentIndex in 0..<segmentCount {
            let text = segmentText(at: segmentIndex)
            guard !text.isEmpty else { continue }

            let start = timestampToSeconds(whisper_full_get_segment_t0(context, Int32(segmentIndex)))
            let end = timestampToSeconds(whisper_full_get_segment_t1(context, Int32(segmentIndex)))
            rawSegments.append(
                RawSegment(
                    index: segmentIndex,
                    text: text,
                    confidence: segmentConfidence(at: segmentIndex),
                    start: start,
                    end: end
                )
            )
        }

        guard !rawSegments.isEmpty else { return [] }

        if purpose == .timingGuide {
            if let tokenSegments = collectTokenTimingSegments(plan: plan), !tokenSegments.isEmpty {
                return tokenSegments
            }

            guard rawSegments.contains(where: { $0.end > $0.start + 0.08 }) else {
                return []
            }

            let segmentTimed = rawSegments.map { raw in
                LocalPipelineBaseSegment(
                    segmentId: "\(plan.chunkId)-seg-\(String(format: "%04d", raw.index + 1))",
                    start: plan.start + raw.start,
                    end: plan.start + raw.end,
                    text: raw.text,
                    confidence: raw.confidence
                )
            }
            return mergeTimingGuideSegments(segmentTimed)
        }

        let segments: [LocalPipelineBaseSegment]
        if rawSegments.contains(where: { $0.end > $0.start + 0.08 }) {
            segments = rawSegments.map { raw in
                LocalPipelineBaseSegment(
                    segmentId: "\(plan.chunkId)-seg-\(String(format: "%04d", raw.index + 1))",
                    start: plan.start + raw.start,
                    end: plan.start + raw.end,
                    text: raw.text,
                    confidence: raw.confidence
                )
            }
        } else {
            segments = synthesizeSegmentTimings(rawSegments, plan: plan)
        }

        return mergeTouchingShortSegments(mergeRawBaseSegments(segments))
    }

    private func collectTokenTimingSegments(plan: LocalPipelineChunkPlan) -> [LocalPipelineBaseSegment]? {
        let segmentCount = Int(whisper_full_n_segments(context))
        var pieces: [LocalPipelineBaseSegment] = []

        for segmentIndex in 0..<segmentCount {
            let tokenCount = Int(whisper_full_n_tokens(context, Int32(segmentIndex)))
            guard tokenCount > 0 else { continue }

            for tokenIndex in 0..<tokenCount {
                let text = tokenText(at: segmentIndex, tokenIndex: tokenIndex)
                guard !text.isEmpty else { continue }

                let tokenData = whisper_full_get_token_data(context, Int32(segmentIndex), Int32(tokenIndex))
                let start = timestampToSeconds(tokenData.t0)
                let end = timestampToSeconds(tokenData.t1)
                guard end > start + 0.02 else { continue }

                pieces.append(
                    LocalPipelineBaseSegment(
                        segmentId: "\(plan.chunkId)-tok-\(String(format: "%04d", segmentIndex + 1))-\(String(format: "%04d", tokenIndex + 1))",
                        start: plan.start + start,
                        end: plan.start + end,
                        text: text,
                        confidence: tokenData.p.isFinite ? Double(tokenData.p) : 0.6
                    )
                )
            }
        }

        guard !pieces.isEmpty else { return nil }
        return mergeTimingGuideSegments(pieces)
    }

    private func mergeTimingGuideSegments(_ segments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [LocalPipelineBaseSegment] = []
        for segment in segments.sorted(by: { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }) {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }

            let gap = segment.start - last.end
            let mergedDuration = segment.end - last.start
            let shouldMerge =
                gap <= Self.timingGuideMergeGap
                && mergedDuration <= Self.timingGuideMaxSegmentDuration
                && (normalizedText(last.text).count < 10 || normalizedText(segment.text).count < 8)

            if shouldMerge {
                merged[merged.count - 1] = LocalPipelineBaseSegment(
                    segmentId: last.segmentId,
                    start: last.start,
                    end: segment.end,
                    text: joinGuideTexts(last.text, segment.text),
                    confidence: max(last.confidence, segment.confidence)
                )
            } else {
                merged.append(segment)
            }
        }

        return merged.filter { !$0.text.isEmpty && $0.end > $0.start + 0.02 }
    }

    private func synthesizeSegmentTimings(
        _ rawSegments: [RawSegment],
        plan: LocalPipelineChunkPlan
    ) -> [LocalPipelineBaseSegment] {
        guard !rawSegments.isEmpty else { return [] }
        let duration = max(plan.end - plan.start, 0.1)
        let totalWeight = max(rawSegments.reduce(0) { $0 + max(normalizedText($1.text).count, 1) }, 1)
        var consumedWeight = 0
        var segments: [LocalPipelineBaseSegment] = []
        segments.reserveCapacity(rawSegments.count)

        for (offset, raw) in rawSegments.enumerated() {
            let weight = max(normalizedText(raw.text).count, 1)
            let startRatio = Double(consumedWeight) / Double(totalWeight)
            consumedWeight += weight
            let endRatio = Double(consumedWeight) / Double(totalWeight)

            let start = plan.start + (duration * startRatio)
            let end = offset == rawSegments.count - 1
                ? plan.end
                : max(plan.start + (duration * endRatio), start + 0.12)

            segments.append(
                LocalPipelineBaseSegment(
                    segmentId: "\(plan.chunkId)-seg-\(String(format: "%04d", raw.index + 1))",
                    start: start,
                    end: min(plan.end, end),
                    text: raw.text,
                    confidence: raw.confidence
                )
            )
        }

        return segments
    }

    private func segmentText(at index: Int) -> String {
        guard let pointer = whisper_full_get_segment_text(context, Int32(index)) else { return "" }
        return String(cString: pointer)
            .replacingOccurrences(of: "�", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenText(at index: Int, tokenIndex: Int) -> String {
        guard let pointer = whisper_full_get_token_text(context, Int32(index), Int32(tokenIndex)) else { return "" }
        return String(cString: pointer)
            .replacingOccurrences(of: "�", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func segmentConfidence(at index: Int) -> Double {
        let tokenCount = Int(whisper_full_n_tokens(context, Int32(index)))
        guard tokenCount > 0 else { return 0.6 }

        var total = 0.0
        var counted = 0

        for tokenIndex in 0..<tokenCount {
            let probability = Double(whisper_full_get_token_p(context, Int32(index), Int32(tokenIndex)))
            guard probability.isFinite else { continue }
            total += probability
            counted += 1
        }

        guard counted > 0 else { return 0.6 }
        return total / Double(counted)
    }

    private func mergeRawBaseSegments(_ rawSegments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
        var merged: [LocalPipelineBaseSegment] = []

        for segment in rawSegments {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }

            if shouldMergeOrSkipDuplicate(last: last, current: segment) {
                merged[merged.count - 1] = LocalPipelineBaseSegment(
                    segmentId: last.segmentId,
                    start: min(last.start, segment.start),
                    end: max(last.end, segment.end),
                    text: last.text.count >= segment.text.count ? last.text : segment.text,
                    confidence: max(last.confidence, segment.confidence)
                )
                continue
            }

            merged.append(segment)
        }

        return merged
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

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            count += 1
        }
        return count
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

    private func joinGuideTexts(_ lhs: String, _ rhs: String) -> String {
        (lhs + rhs)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedLanguage(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "auto" {
            return nil
        }
        return trimmed
    }

    private func timestampToSeconds(_ value: Int64) -> TimeInterval {
        max(0, Double(value) / Self.timestampScale)
    }

    private func recommendedThreadCount() -> Int {
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        return max(1, min(cpuCount, 8))
    }

    private func withOptionalCString<Result>(
        _ value: String?,
        body: (UnsafePointer<CChar>?) throws -> Result
    ) rethrows -> Result {
        guard let value, !value.isEmpty else {
            return try body(nil)
        }
        return try value.withCString { pointer in
            try body(pointer)
        }
    }
}
