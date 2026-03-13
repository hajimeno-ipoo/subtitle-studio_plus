import Foundation

struct AudioAnalysisService {
    static let stableModel = "gemini-3-flash-preview"
    private static let initialProgress = 10.0
    private static let chunkProgressBudget = 90.0
    private let waveformService = WaveformService()

    func analyze(fileURL: URL, apiKey: String, progress: @escaping @Sendable (AnalysisProgress) async -> Void) async throws -> [SubtitleItem] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleStudioError.missingAPIKey
        }

        await progress(makeProgress(
            phase: .loadingAudio,
            message: "音声を読み込み中...",
            actual: 2,
            display: 2
        ))

        await progress(makeProgress(
            phase: .loadingAudio,
            message: "音声をデコード中...",
            actual: 5,
            display: 5
        ))
        let targetRate = 16_000.0
        let converted = try waveformService.convertedMonoSamples(url: fileURL, targetSampleRate: targetRate)

        await progress(makeProgress(
            phase: .optimizingAudio,
            message: "音声データを最適化中 (16kHz Mono)...",
            actual: 8,
            display: 8
        ))

        let chunkSize = Int(targetRate * 300)
        let chunkCount = max(1, Int(ceil(Double(converted.samples.count) / Double(chunkSize))))
        var subtitles: [SubtitleItem] = []
        var firstError: Error?

        await progress(makeProgress(
            phase: .chunking,
            message: "データ分割中...",
            actual: Self.initialProgress,
            display: Self.initialProgress,
            totalChunks: chunkCount
        ))

        for chunkIndex in 0..<chunkCount {
            let chunkNumber = chunkIndex + 1
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, converted.samples.count)
            let chunk = Array(converted.samples[start..<end])
            let wavData = makeWAV(samples: chunk, sampleRate: Int(targetRate))
            let chunkProgress = Self.chunkProgressBudget / Double(chunkCount)
            let chunkStartPercent = Self.initialProgress + (Double(chunkIndex) * chunkProgress)
            let uploadStartPercent = chunkStartPercent + (chunkProgress * 0.3)
            let waitingCapPercent = chunkStartPercent + (chunkProgress * 0.8)
            let parsingPercent = chunkStartPercent + (chunkProgress * 0.85)
            let chunkEndPercent = Self.initialProgress + (Double(chunkNumber) * chunkProgress)

            await progress(makeProgress(
                phase: .chunking,
                message: "データ分割中 (\(chunkNumber)/\(chunkCount)) ...",
                actual: chunkStartPercent,
                display: chunkStartPercent,
                currentChunk: chunkNumber,
                totalChunks: chunkCount
            ))

            await progress(makeProgress(
                phase: .requestingChunk,
                message: "AI解析を実行中 (\(chunkNumber)/\(chunkCount)) ...",
                actual: uploadStartPercent,
                display: uploadStartPercent,
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
                let text = try await requestSRTChunk(
                    wavData: wavData,
                    apiKey: apiKey,
                    prompt: prompt,
                    currentChunk: chunkNumber,
                    totalChunks: chunkCount,
                    startPercent: uploadStartPercent,
                    waitingCapPercent: waitingCapPercent,
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
                    message: "字幕データを処理中 (\(chunkNumber)/\(chunkCount)) ...",
                    actual: parsingPercent,
                    display: parsingPercent,
                    currentChunk: chunkNumber,
                    totalChunks: chunkCount
                ))
            } catch {
                firstError = firstError ?? error
                await progress(makeProgress(
                    phase: .failed,
                    message: "解析エラー (スキップ) ...",
                    actual: chunkEndPercent,
                    display: chunkEndPercent,
                    currentChunk: chunkNumber,
                    totalChunks: chunkCount
                ))
            }

            if chunkIndex < chunkCount - 1 {
                await progress(makeProgress(
                    phase: .requestingChunk,
                    message: "レート制限待機中...",
                    actual: chunkEndPercent,
                    display: chunkEndPercent,
                    currentChunk: chunkNumber,
                    totalChunks: chunkCount
                ))
                try? await Task.sleep(for: .seconds(2))
            }
        }

        guard !subtitles.isEmpty else {
            throw firstError ?? SubtitleStudioError.emptyGeminiResponse
        }

        await progress(makeProgress(
            phase: .mergingChunks,
            message: "字幕データをまとめています...",
            actual: 96,
            display: 99,
            currentChunk: chunkCount,
            totalChunks: chunkCount
        ))
        try? await Task.sleep(for: .milliseconds(180))
        await progress(makeProgress(
            phase: .completed,
            message: "全工程完了！",
            actual: 100,
            display: 100,
            currentChunk: chunkCount,
            totalChunks: chunkCount
        ))
        return subtitles
    }

    private func requestSRTChunk(
        wavData: Data,
        apiKey: String,
        prompt: String,
        currentChunk: Int,
        totalChunks: Int,
        startPercent: Double,
        waitingCapPercent: Double,
        progress: @escaping @Sendable (AnalysisProgress) async -> Void
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.stableModel):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(
            GeminiRequestBody(
                contents: [
                    .init(parts: [
                        .init(text: nil, inlineData: .init(mimeType: "audio/wav", data: wavData.base64EncodedString())),
                        .init(text: prompt, inlineData: nil),
                    ]),
                ],
                generationConfig: .init(temperature: 0.1)
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        let progressTask = Task {
            var currentPercent = startPercent
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                currentPercent = min(waitingCapPercent, currentPercent + 0.5)
                await progress(makeProgress(
                    phase: .requestingChunk,
                    message: "AI解析を実行中 (\(currentChunk)/\(totalChunks)) ...",
                    actual: currentPercent,
                    display: currentPercent,
                    currentChunk: currentChunk,
                    totalChunks: totalChunks
                ))
                if currentPercent >= waitingCapPercent {
                    return
                }
            }
        }

        defer { progressTask.cancel() }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown Gemini error"
            throw SubtitleStudioError.network("Gemini request failed: \(body)")
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        if let blockReason = decoded.promptFeedback?.blockReason {
            throw SubtitleStudioError.network("Gemini blocked the request: \(blockReason)")
        }
        if let finishReason = decoded.candidates?.first?.finishReason,
           finishReason != "STOP",
           finishReason != "MAX_TOKENS" {
            throw SubtitleStudioError.network("Gemini request finished unexpectedly: \(finishReason)")
        }

        let text = decoded.candidates?.first?.content.parts.compactMap(\.text).joined(separator: "\n") ?? ""
        let cleaned = Self.cleanGeminiText(text)
        guard !cleaned.isEmpty else {
            throw SubtitleStudioError.emptyGeminiResponse
        }
        return cleaned
    }

    private func makeProgress(
        phase: AnalysisPhase,
        message: String,
        actual: Double,
        display: Double,
        currentChunk: Int = 0,
        totalChunks: Int = 0
    ) -> AnalysisProgress {
        AnalysisProgress(
            phase: phase,
            message: message,
            actualPercent: actual,
            displayPercent: display,
            currentChunk: currentChunk,
            totalChunks: totalChunks
        )
    }

    static func cleanGeminiText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```srt", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct GeminiGenerateResponse: Decodable {
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
