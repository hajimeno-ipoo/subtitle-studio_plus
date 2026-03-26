import Foundation

struct LocalPipelineAssembler: Sendable {
    func assemble(
        runId: String,
        sourceFileName: String,
        baseModel: LocalBaseModel,
        correctedSegments: [LocalPipelineCorrectedSegment]
    ) -> LocalPipelineAssemblyResult {
        let sortedSegments = correctedSegments.sorted {
            if $0.startTime == $1.startTime {
                return $0.endTime < $1.endTime
            }
            return $0.startTime < $1.startTime
        }
        let normalizedSegments = normalizeTimeline(sortedSegments)

        let subtitles = normalizedSegments.map {
            SubtitleItem(startTime: $0.startTime, endTime: $0.endTime, text: $0.finalTranscript)
        }

        let finalOutput = LocalPipelineFinalOutput(
            runId: runId,
            engineType: SRTGenerationEngine.localPipeline.rawValue,
            sourceFileName: sourceFileName,
            baseModel: baseModel.rawValue,
            alignmentModel: "aeneas",
            segments: normalizedSegments
        )

        return LocalPipelineAssemblyResult(subtitles: subtitles, finalOutput: finalOutput)
    }

    private func normalizeTimeline(_ segments: [LocalPipelineCorrectedSegment]) -> [LocalPipelineCorrectedSegment] {
        guard !segments.isEmpty else { return [] }

        var normalized = segments

        for index in normalized.indices.dropLast() {
            let nextIndex = normalized.index(after: index)
            let current = normalized[index]
            let next = normalized[nextIndex]

            guard current.endTime > next.startTime else { continue }

            let boundary = max(
                current.startTime + 0.15,
                min(
                    next.endTime - 0.15,
                    (current.endTime + next.startTime) / 2
                )
            )

            normalized[index].endTime = boundary
            normalized[nextIndex].startTime = max(boundary, next.startTime)
        }

        return normalized.map { segment in
            var adjusted = segment
            if adjusted.endTime <= adjusted.startTime {
                adjusted.endTime = adjusted.startTime + 0.3
            }
            return adjusted
        }
    }
}
