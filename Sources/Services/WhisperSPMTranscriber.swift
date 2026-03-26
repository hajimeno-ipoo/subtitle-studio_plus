import Foundation
import whisper

protocol LocalWhisperTranscriberBuilding: Sendable {
    func build(modelURL: URL) throws -> any LocalWhisperTranscribing
}

protocol LocalWhisperTranscribing: Sendable {
    func transcribe(
        plan: LocalPipelineChunkPlan,
        samples: [Float],
        settings: LocalWhisperDecodingSettings
    ) throws -> LocalPipelineBaseChunkOutput

    var runtimeDiagnostics: [String] { get }
}

struct LocalWhisperDecodingSettings: Sendable {
    var baseModel: LocalBaseModel
    var language: String
    var initialPrompt: String
    var temperature: Double
    var beamSize: Int
    var noSpeechThreshold: Double
    var logprobThreshold: Double
}

struct WhisperSPMTranscriberBuilder: LocalWhisperTranscriberBuilding {
    func build(modelURL: URL) throws -> any LocalWhisperTranscribing {
        try WhisperSPMTranscriber(modelURL: modelURL)
    }
}

final class WhisperSPMTranscriber: LocalWhisperTranscribing, @unchecked Sendable {
    private static let timestampScale = 100.0
    private static let tokenSegmentTargetCharacters = 6
    private static let tokenSegmentMaxCharacters = 8
    private static let tokenSegmentHardMaxDuration: TimeInterval = 3.2
    private static let tokenSegmentStrongGap: TimeInterval = 0.28
    private static let tokenSegmentSoftGap: TimeInterval = 0.16
    private static let maxSegmentLength = 18

    private struct WhisperTokenPiece {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var confidence: Double
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
            "use_gpu=\(contextParams.use_gpu)",
            "flash_attn=\(contextParams.flash_attn)"
        ]
    }

    deinit {
        whisper_free(context)
    }

    func transcribe(
        plan: LocalPipelineChunkPlan,
        samples: [Float],
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
        params.no_timestamps = false
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.token_timestamps = true
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

        let normalizedLanguage = normalizedLanguage(settings.language)
        let prompt = settings.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try withOptionalCString(normalizedLanguage) { languagePointer in
            params.language = languagePointer
            params.detect_language = languagePointer == nil

            return try withOptionalCString(prompt) { promptPointer in
                params.initial_prompt = promptPointer

                return try samples.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        throw LocalPipelineError.baseTranscriptionFailed("whisper.cpp に渡す音声データが空でした。")
                    }
                    return whisper_full(context, params, baseAddress, Int32(buffer.count))
                }
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
            segments: collectSegments(plan: plan)
        )
    }

    var runtimeDiagnostics: [String] {
        runtimeDiagnosticsStorage
    }

    private func collectSegments(plan: LocalPipelineChunkPlan) -> [LocalPipelineBaseSegment] {
        let segmentCount = Int(whisper_full_n_segments(context))
        var segments: [LocalPipelineBaseSegment] = []
        segments.reserveCapacity(segmentCount)

        for segmentIndex in 0..<segmentCount {
            let text = segmentText(at: segmentIndex)
            guard !text.isEmpty else { continue }

            let confidence = segmentConfidence(at: segmentIndex)
            if let tokenSegments = makeTokenSegments(plan: plan, segmentIndex: segmentIndex, fallbackConfidence: confidence),
               !tokenSegments.isEmpty {
                segments.append(contentsOf: tokenSegments)
                continue
            }

            let start = plan.start + timestampToSeconds(whisper_full_get_segment_t0(context, Int32(segmentIndex)))
            let end = plan.start + max(
                timestampToSeconds(whisper_full_get_segment_t1(context, Int32(segmentIndex))),
                timestampToSeconds(whisper_full_get_segment_t0(context, Int32(segmentIndex))) + 0.08
            )
            segments.append(
                LocalPipelineBaseSegment(
                    segmentId: "\(plan.chunkId)-seg-\(String(format: "%04d", segmentIndex + 1))",
                    start: start,
                    end: end,
                    text: text,
                    confidence: confidence
                )
            )
        }

        return mergeTouchingShortSegments(mergeRawBaseSegments(segments))
    }

    private func segmentText(at index: Int) -> String {
        guard let pointer = whisper_full_get_segment_text(context, Int32(index)) else { return "" }
        return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func makeTokenSegments(
        plan: LocalPipelineChunkPlan,
        segmentIndex: Int,
        fallbackConfidence: Double
    ) -> [LocalPipelineBaseSegment]? {
        let pieces = extractTokenPieces(plan: plan, segmentIndex: segmentIndex, fallbackConfidence: fallbackConfidence)
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

            let segmentIDBase = (segmentIndex * 100) + offset + 1
            return LocalPipelineBaseSegment(
                segmentId: "\(plan.chunkId)-seg-\(String(format: "%04d", segmentIDBase))",
                start: first.start,
                end: max(last.end, first.start + 0.08),
                text: text,
                confidence: group.map(\.confidence).max() ?? fallbackConfidence
            )
        }

        guard segments.count > 1 else { return nil }
        return segments
    }

    private func extractTokenPieces(
        plan: LocalPipelineChunkPlan,
        segmentIndex: Int,
        fallbackConfidence: Double
    ) -> [WhisperTokenPiece] {
        let tokenCount = Int(whisper_full_n_tokens(context, Int32(segmentIndex)))
        guard tokenCount > 0 else { return [] }

        var pieces: [WhisperTokenPiece] = []
        pieces.reserveCapacity(tokenCount)

        for tokenIndex in 0..<tokenCount {
            guard let textPointer = whisper_full_get_token_text(context, Int32(segmentIndex), Int32(tokenIndex)) else {
                continue
            }
            let text = String(cString: textPointer)
            let normalized = normalizedText(text)
            guard !normalized.isEmpty else { continue }
            if text.hasPrefix("[_"), text.hasSuffix("]") {
                continue
            }

            let tokenData = whisper_full_get_token_data(context, Int32(segmentIndex), Int32(tokenIndex))
            let start = plan.start + timestampToSeconds(tokenData.t0)
            let end = plan.start + max(timestampToSeconds(tokenData.t1), timestampToSeconds(tokenData.t0) + 0.05)

            pieces.append(
                WhisperTokenPiece(
                    start: start,
                    end: end,
                    text: text,
                    confidence: tokenData.p.isFinite ? Double(tokenData.p) : fallbackConfidence
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
