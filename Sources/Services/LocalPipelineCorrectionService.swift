import Foundation

struct LocalCorrectionDictionary: Codable, Equatable, Sendable {
    struct Rule: Codable, Equatable, Sendable {
        var type: String
        var from: String
        var to: String
    }

    var version: String
    var language: String
    var description: String
    var rules: [Rule]
}

struct LocalPipelineCorrectionService: Sendable {
    func correct(
        runId: String,
        draftSegments: [LocalPipelineDraftSegment],
        alignedSegments: [LocalPipelineAlignedSegment],
        settings: LocalPipelineSettings,
        allowDictionaryCorrections: Bool = true
    ) throws -> [LocalPipelineCorrectedSegment] {
        let dictionaryRules = try loadDictionaryRules(from: settings.correctionDictionaryPath)
        let alignedByID = Dictionary(uniqueKeysWithValues: alignedSegments.map { ($0.segmentId, $0) })

        return draftSegments.map { segment in
            let aligned = alignedByID[segment.segmentId]
            let sourceText = segment.text
            let corrected = applyRules(
                to: sourceText,
                dictionaryRules: dictionaryRules,
                allowDictionaryCorrections: allowDictionaryCorrections
            )
            let records = makeRecords(before: sourceText, after: corrected)

            let proposedStart = aligned?.start ?? segment.startTime
            let proposedEnd = aligned?.end ?? segment.endTime
            let timing = resolvedTiming(
                start: proposedStart,
                end: proposedEnd,
                fallbackStart: segment.startTime,
                fallbackEnd: segment.endTime
            )

            return LocalPipelineCorrectedSegment(
                id: UUID().uuidString.uppercased(),
                segmentId: segment.segmentId,
                startTime: timing.start,
                endTime: timing.end,
                baseTranscript: sourceText,
                finalTranscript: corrected,
                corrections: records
            )
        }
    }

    private func resolvedTiming(
        start: TimeInterval,
        end: TimeInterval,
        fallbackStart: TimeInterval,
        fallbackEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let candidateIsValid = start >= 0 && end > start
        if candidateIsValid {
            return (start, end)
        }

        let fallbackIsValid = fallbackStart >= 0 && fallbackEnd > fallbackStart
        if fallbackIsValid {
            return (fallbackStart, fallbackEnd)
        }

        return (max(0, fallbackStart), max(fallbackStart + 0.1, fallbackEnd, start + 0.1))
    }

    private func loadDictionaryRules(from rawPath: String) throws -> [LocalCorrectionDictionary.Rule] {
        guard let url = resolveExistingFile(rawPath) else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalPipelineError.correctionFailed("Missing dictionary file: \(url.path)")
        }
        let data = try Data(contentsOf: url)
        do {
            let payload = try JSONDecoder().decode(LocalCorrectionDictionary.self, from: data)
            return payload.rules
        } catch {
            throw LocalPipelineError.correctionFailed("Invalid dictionary JSON: \(error.localizedDescription)")
        }
    }

    private func applyRules(
        to text: String,
        dictionaryRules: [LocalCorrectionDictionary.Rule],
        allowDictionaryCorrections: Bool
    ) -> String {
        guard allowDictionaryCorrections else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var current = text

        for rule in dictionaryRules {
            switch rule.type.lowercased() {
            case "exact":
                current = current.replacingOccurrences(of: rule.from, with: rule.to)
            case "regex":
                if let regex = try? NSRegularExpression(pattern: rule.from, options: []) {
                    let range = NSRange(current.startIndex..., in: current)
                    current = regex.stringByReplacingMatches(in: current, options: [], range: range, withTemplate: rule.to)
                }
            default:
                continue
            }
        }

        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRecords(before: String, after: String) -> [LocalPipelineCorrectionRecord] {
        guard before != after else { return [] }
        return [LocalPipelineCorrectionRecord(type: "dictionary", before: before, after: after)]
    }

    private func resolveExistingFile(_ rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = AppRuntimePathResolver().candidateURLs(forResourcePath: trimmed)
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
}
