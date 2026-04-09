import Foundation

extension LocalPipelineService {
    func makeChunkPlans(
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

    func buildWhisperArguments(
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

    func buildAeneasArguments(
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

    func buildWhisperPrompt(userPrompt: String) -> String {
        let basePrompt = LocalPipelineServiceConfig.whisperBasePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserPrompt.isEmpty else { return basePrompt }
        return basePrompt + "\n" + trimmedUserPrompt
    }

    func whisperDecodingSettings(
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

    func wrapWhisperError(_ error: Error) -> LocalPipelineError {
        if let pipelineError = error as? LocalPipelineError {
            return pipelineError
        }
        return LocalPipelineError.baseTranscriptionFailed(error.localizedDescription)
    }

    func parseWhisperOutput(
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

    func makeTokenSegments(
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
                (gap >= LocalPipelineServiceConfig.tokenSegmentStrongGap && currentLength >= 2)
                || (gap >= LocalPipelineServiceConfig.tokenSegmentSoftGap && currentLength >= LocalPipelineServiceConfig.tokenSegmentTargetCharacters)
                || nextLength > LocalPipelineServiceConfig.tokenSegmentMaxCharacters
                || durationWithNext > LocalPipelineServiceConfig.tokenSegmentHardMaxDuration
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

    func extractTokenPieces(
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

    func collapseTinyTokenGroups(_ groups: [[WhisperTokenPiece]]) -> [[WhisperTokenPiece]] {
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

    func mergeTouchingShortSegments(_ segments: [LocalPipelineBaseSegment]) -> [LocalPipelineBaseSegment] {
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

    func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            count += 1
        }
        return count
    }

    func normalizeJSONDataForDecoding(_ data: Data) -> Data {
        if String(data: data, encoding: .utf8) != nil {
            return data
        }
        return Data(String(decoding: data, as: UTF8.self).utf8)
    }

    func extractRawSegments(from payload: Any) -> [Any] {
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

    func extractSegmentRange(_ payload: Any) -> (start: Double, end: Double)? {
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

    func parseWhisperTimestamp(_ value: String) -> Double? {
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

    func extractString(_ payload: Any, keys: [String]) -> String? {
        guard let dictionary = payload as? [String: Any] else { return nil }
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func extractDouble(_ payload: Any, keys: [String]) -> Double? {
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

    func extractConfidence(_ payload: Any) -> Double {
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

    func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "。.!！？?♪".contains(last)
    }

    func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
    }

    func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.max(lower, Swift.min(upper, value))
    }

    func extractSampleSlice(from samples: [Float], sampleRate: Double, start: TimeInterval, end: TimeInterval) -> ArraySlice<Float> {
        let lower = max(0, Int((start * sampleRate).rounded(.down)))
        let upper = min(samples.count, Int((end * sampleRate).rounded(.up)))
        guard upper > lower else { return [] }
        return samples[lower..<upper]
    }

    func extractSamples(from samples: [Float], sampleRate: Double, start: TimeInterval, end: TimeInterval) -> [Float] {
        Array(extractSampleSlice(from: samples, sampleRate: sampleRate, start: start, end: end))
    }

    func writePCM16WAV<S: Collection>(samples: S, sampleRate: Double, to url: URL) throws where S.Element == Float {
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

    func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try jsonEncoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    func writeText(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    func buildProcessEnvironment(extraExecutableURLs: [URL]) -> [String: String] {
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
}
