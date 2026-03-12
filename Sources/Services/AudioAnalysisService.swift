import Foundation

struct AudioAnalysisService {
    static let stableModel = "gemini-3-flash-preview"
    private let waveformService = WaveformService()

    func analyze(fileURL: URL, apiKey: String, progress: @escaping @Sendable (String) async -> Void) async throws -> [SubtitleItem] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleStudioError.missingAPIKey
        }

        await progress("Loading audio... 2%")
        let decoded = try waveformService.decodedMonoSamples(url: fileURL)
        await progress("Optimizing audio data (16kHz mono)... 8%")

        let targetRate = 16_000.0
        let downsampled = downsample(samples: decoded.samples, sourceRate: decoded.sampleRate, targetRate: targetRate)
        let chunkSize = Int(targetRate * 300)
        let chunkCount = max(1, Int(ceil(Double(downsampled.count) / Double(chunkSize))))
        var subtitles: [SubtitleItem] = []
        var firstError: Error?

        for chunkIndex in 0..<chunkCount {
            let currentBase = 10.0 + (Double(chunkIndex) * (90.0 / Double(chunkCount)))
            await progress("Splitting audio (\(chunkIndex + 1)/\(chunkCount)) ... \(Int(currentBase))%")
            let start = chunkIndex * chunkSize
            let end = min(start + chunkSize, downsampled.count)
            let chunk = Array(downsampled[start..<end])
            let wavData = makeWAV(samples: chunk, sampleRate: Int(targetRate))
            let prompt = """
            この音声は動画の一部（\(chunkIndex + 1)分割目）です。
            聞こえてくる日本語の会話や歌詞を、SRT形式の字幕として書き起こしてください。

            【極めて重要なルール】
            1. 自然な区切りで区切ること
            2. 相対時間は 00:00:00,000 から始めること
            3. 出力はSRT本文のみで、説明やMarkdownを含めないこと
            4. 短いフレーズも漏らさないこと
            """

            await progress("Running Gemini analysis (\(chunkIndex + 1)/\(chunkCount)) ... \(Int(currentBase + 10))%")
            do {
                let text = try await generateSRT(wavData: wavData, apiKey: apiKey, prompt: prompt)
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
            } catch {
                firstError = firstError ?? error
                await progress("Chunk skipped because of an API error ... \(Int(currentBase + (90.0 / Double(chunkCount))))%")
            }

            if chunkIndex < chunkCount - 1 {
                try? await Task.sleep(for: .seconds(2))
            }
        }

        guard !subtitles.isEmpty else {
            throw firstError ?? SubtitleStudioError.emptyGeminiResponse
        }

        await progress("All steps completed! 100%")
        try? await Task.sleep(for: .seconds(0.8))
        return subtitles
    }

    private func generateSRT(wavData: Data, apiKey: String, prompt: String) async throws -> String {
        struct RequestBody: Encodable {
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

        struct ResponseBody: Decodable {
            struct PromptFeedback: Decodable {
                struct SafetyRating: Decodable {
                    let category: String?
                    let probability: String?
                }

                let blockReason: String?
                let safetyRatings: [SafetyRating]?
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

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.stableModel):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                contents: [
                    .init(parts: [
                        .init(text: prompt, inlineData: nil),
                        .init(text: nil, inlineData: .init(mimeType: "audio/wav", data: wavData.base64EncodedString())),
                    ]),
                ],
                generationConfig: .init(temperature: 0.1)
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            throw SubtitleStudioError.network("Gemini request failed: \(text)")
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        if let feedback = decoded.promptFeedback?.blockReason {
            throw SubtitleStudioError.network("Gemini blocked the request: \(feedback)")
        }

        if let finishReason = decoded.candidates?.first?.finishReason,
           finishReason != "STOP",
           finishReason != "MAX_TOKENS" {
            throw SubtitleStudioError.network("Gemini stopped without subtitle text: \(finishReason)")
        }

        let text = decoded.candidates?
            .first?
            .content
            .parts
            .compactMap(\.text)
            .joined(separator: "\n")
            .replacingOccurrences(of: "```srt", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let text, !text.isEmpty else {
            throw SubtitleStudioError.emptyGeminiResponse
        }
        return text
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

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
