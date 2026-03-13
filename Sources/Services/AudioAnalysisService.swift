import Foundation

struct AudioAnalysisService {
    static let stableModel = "gemini-3-flash-preview"
    private let waveformService = WaveformService()

    func analyze(fileURL: URL, apiKey: String, progress: @escaping @Sendable (AnalysisProgress) async -> Void) async throws -> [SubtitleItem] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleStudioError.missingAPIKey
        }

        await progress(makeProgress(
            phase: .loadingAudio,
            message: "Loading audio...",
            actual: 2,
            display: 8
        ))
        let decoded = try waveformService.decodedMonoSamples(url: fileURL)

        await progress(makeProgress(
            phase: .optimizingAudio,
            message: "Optimizing audio data (16kHz mono)...",
            actual: 10,
            display: 16
        ))

        let targetRate = 16_000.0
        let downsampled = downsample(samples: decoded.samples, sourceRate: decoded.sampleRate, targetRate: targetRate)
        let chunkSize = Int(targetRate * 300)
        let chunkCount = max(1, Int(ceil(Double(downsampled.count) / Double(chunkSize))))
        var subtitles: [SubtitleItem] = []
        var firstError: Error?

        await progress(makeProgress(
            phase: .chunking,
            message: "Splitting audio into \(chunkCount) chunk(s)...",
            actual: 18,
            display: 22,
            totalChunks: chunkCount
        ))

        for chunkIndex in 0..<chunkCount {
            let chunkNumber = chunkIndex + 1
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, downsampled.count)
            let chunk = Array(downsampled[start..<end])
            let wavData = makeWAV(samples: chunk, sampleRate: Int(targetRate))
            let chunkRequestPercent = 22 + (6 * (Double(chunkIndex) / Double(chunkCount)))
            let streamStartPercent = 28 + (60 * (Double(chunkIndex) / Double(chunkCount)))
            let streamEndPercent = 28 + (60 * (Double(chunkNumber) / Double(chunkCount)))
            let streamDisplayCap = max(streamStartPercent, streamEndPercent - 2)

            await progress(makeProgress(
                phase: .requestingChunk,
                message: "Preparing Gemini request (\(chunkNumber)/\(chunkCount))...",
                actual: chunkRequestPercent,
                display: streamStartPercent,
                currentChunk: chunkNumber,
                totalChunks: chunkCount
            ))

            let prompt = """
      この音声は動画の一部（\(chunkNumber)分割目）です。
      聞こえてくる日本語の会話や歌詞を、SRT形式の字幕として書き起こしてください。
      
      【極めて重要なルール】
      1. **自然な区切り**: 歌詞のフレーズや会話の息継ぎごとに区切ってください。
         - 禁止: 8秒ごと等の機械的な等間隔分割。
         - 禁止: 文の途中で不自然に切ること。
      2. **正確なタイムスタンプ**: 
         - このファイル内での相対時間は「00:00:00,000」から始まります。正確に聞き取って時間を刻んでください。
      3. **出力形式**:
         - SRTデータのみを出力してください。挨拶やコードブロック(markdown)は不要です。
      4. **欠落防止**:
         - 小さな声や短いフレーズも漏らさず書き起こしてください。
"""

            do {
                let text = try await streamSRTChunk(
                    wavData: wavData,
                    apiKey: apiKey,
                    prompt: prompt,
                    currentChunk: chunkNumber,
                    totalChunks: chunkCount,
                    streamStartPercent: streamStartPercent,
                    streamDisplayCap: streamDisplayCap,
                    progress: progress
                )
                let chunkItems = SRTCodec.parseSRT(text)
                guard !chunkItems.isEmpty else {
                    throw SubtitleStudioError.invalidSRTResponse
                }
                let offset = Double(start) / targetRate
                for item in chunkItems {
                    subtitles.append(
                        SubtitleItem(
                            startTime: item.startTime + offset,
                            endTime: item.endTime + offset,
                            text: item.text
                        )
                    )
                }

                await progress(makeProgress(
                    phase: .parsingChunk,
                    message: "Parsing subtitles (\(chunkNumber)/\(chunkCount))...",
                    actual: min(streamEndPercent, streamDisplayCap + 1),
                    display: min(streamEndPercent, streamDisplayCap + 1),
                    currentChunk: chunkNumber,
                    totalChunks: chunkCount
                ))
            } catch {
                firstError = firstError ?? error
                await progress(makeProgress(
                    phase: .failed,
                    message: "Chunk skipped because of an API error (\(chunkNumber)/\(chunkCount)).",
                    actual: streamDisplayCap,
                    display: streamDisplayCap,
                    currentChunk: chunkNumber,
                    totalChunks: chunkCount
                ))
            }

            if chunkIndex < chunkCount - 1 {
                try? await Task.sleep(for: .seconds(1))
            }
        }

        guard !subtitles.isEmpty else {
            throw firstError ?? SubtitleStudioError.emptyGeminiResponse
        }

        await progress(makeProgress(
            phase: .mergingChunks,
            message: "Merging subtitle chunks...",
            actual: 96,
            display: 99,
            currentChunk: chunkCount,
            totalChunks: chunkCount
        ))
        try? await Task.sleep(for: .milliseconds(180))
        await progress(makeProgress(
            phase: .completed,
            message: "All steps completed!",
            actual: 100,
            display: 100,
            currentChunk: chunkCount,
            totalChunks: chunkCount
        ))
        return subtitles
    }

    private func streamSRTChunk(
        wavData: Data,
        apiKey: String,
        prompt: String,
        currentChunk: Int,
        totalChunks: Int,
        streamStartPercent: Double,
        streamDisplayCap: Double,
        progress: @escaping @Sendable (AnalysisProgress) async -> Void
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.stableModel):streamGenerateContent?alt=sse")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(
            GeminiRequestBody(
                contents: [
                    .init(parts: [
                        .init(text: prompt, inlineData: nil),
                        .init(text: nil, inlineData: .init(mimeType: "audio/wav", data: wavData.base64EncodedString())),
                    ]),
                ],
                generationConfig: .init(temperature: 0.1)
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = try await collectBody(from: bytes)
            throw SubtitleStudioError.network("Gemini request failed: \(body)")
        }

        var accumulated = ""
        var eventCount = 0
        var lastFinishReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }
            if payload == "[DONE]" { break }

            let event = try Self.parseSSEPayload(payload)
            if let blockReason = event.blockReason {
                throw SubtitleStudioError.network("Gemini blocked the request: \(blockReason)")
            }
            if let finishReason = event.finishReason {
                lastFinishReason = finishReason
            }
            guard !event.text.isEmpty else { continue }

            eventCount += 1
            accumulated = Self.mergeStreamText(existing: accumulated, incoming: event.text)
            let actualPercent = min(
                streamDisplayCap,
                streamStartPercent + 3 + (Double(eventCount - 1) * 4)
            )

            await progress(makeProgress(
                phase: .streamingChunk,
                message: "Running Gemini analysis (\(currentChunk)/\(totalChunks)) ...",
                actual: actualPercent,
                display: streamDisplayCap,
                partialTranscript: accumulated,
                currentChunk: currentChunk,
                totalChunks: totalChunks
            ))
        }

        if let lastFinishReason, lastFinishReason != "STOP", lastFinishReason != "MAX_TOKENS" {
            throw SubtitleStudioError.streamingFailed(lastFinishReason)
        }

        let cleaned = Self.cleanGeminiText(accumulated)
        guard !cleaned.isEmpty else {
            throw SubtitleStudioError.emptyGeminiResponse
        }
        return cleaned
    }

    private func collectBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body = ""
        for try await byte in bytes {
            body.append(Character(UnicodeScalar(byte)))
        }
        return body
    }

    private func makeProgress(
        phase: AnalysisPhase,
        message: String,
        actual: Double,
        display: Double,
        partialTranscript: String = "",
        currentChunk: Int = 0,
        totalChunks: Int = 0
    ) -> AnalysisProgress {
        AnalysisProgress(
            phase: phase,
            message: message,
            actualPercent: actual,
            displayPercent: display,
            partialTranscript: partialTranscript,
            currentChunk: currentChunk,
            totalChunks: totalChunks
        )
    }

    static func parseSSEPayload(_ payload: String) throws -> StreamEvent {
        let decoded = try JSONDecoder().decode(GeminiStreamResponse.self, from: Data(payload.utf8))
        return StreamEvent(
            text: cleanGeminiText(decoded.candidates?.first?.content.parts.compactMap(\.text).joined(separator: "\n") ?? ""),
            finishReason: decoded.candidates?.first?.finishReason,
            blockReason: decoded.promptFeedback?.blockReason
        )
    }

    static func mergeStreamText(existing: String, incoming: String) -> String {
        guard !incoming.isEmpty else { return existing }
        guard !existing.isEmpty else { return incoming }
        if incoming == existing || existing.hasSuffix(incoming) {
            return existing
        }
        if incoming.hasPrefix(existing) {
            return incoming
        }
        return existing + incoming
    }

    static func cleanGeminiText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```srt", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func downsample(samples: [Float], sourceRate: Double, targetRate: Double) -> [Float] {
        if sourceRate <= targetRate {
            return samples
        }
        let ratio = sourceRate / targetRate
        let targetCount = Int(Double(samples.count) / ratio)
        var output: [Float] = []
        output.reserveCapacity(targetCount)

        for index in 0..<targetCount {
            let sourceIndex = Int(Double(index) * ratio)
            if sourceIndex < samples.count {
                output.append(samples[sourceIndex])
            }
        }
        return output
    }

    private func makeWAV(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * bitsPerSample / 8
        let payloadSize = UInt32(samples.count * 2)

        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(36 + payloadSize).littleEndianData)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(numChannels.littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(byteRate.littleEndianData)
        data.append(blockAlign.littleEndianData)
        data.append(bitsPerSample.littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(payloadSize.littleEndianData)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            data.append(int16.littleEndianData)
        }
        return data
    }
}

struct StreamEvent: Equatable {
    let text: String
    let finishReason: String?
    let blockReason: String?
}

private struct GeminiRequestBody: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            struct InlineData: Encodable {
                let mimeType: String
                let data: String

                enum CodingKeys: String, CodingKey {
                    case mimeType
                    case data
                }
            }

            let text: String?
            let inlineData: InlineData?

            enum CodingKeys: String, CodingKey {
                case text
                case inlineData
            }
        }

        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiStreamResponse: Decodable {
    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]
        }
        let finishReason: String?
        let content: Content
    }

    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
