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

        let subtitles = sortedSegments.map {
            SubtitleItem(startTime: $0.startTime, endTime: $0.endTime, text: $0.finalTranscript)
        }

        let finalOutput = LocalPipelineFinalOutput(
            runId: runId,
            engineType: SRTGenerationEngine.localPipeline.rawValue,
            sourceFileName: sourceFileName,
            baseModel: baseModel.rawValue,
            alignmentModel: "aeneas",
            segments: sortedSegments
        )

        return LocalPipelineAssemblyResult(subtitles: subtitles, finalOutput: finalOutput)
    }
}
