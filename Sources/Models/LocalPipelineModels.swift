import Foundation

struct LocalPipelineChunkPlan: Codable, Equatable, Sendable {
    var chunkId: String
    var start: TimeInterval
    var end: TimeInterval
}

struct LocalPipelineChunksIndex: Codable, Equatable, Sendable {
    var runId: String
    var sourceDuration: TimeInterval
    var chunkLengthSeconds: Double
    var overlapSeconds: Double
    var chunks: [LocalPipelineChunkPlan]
}

struct LocalPipelineBaseSegment: Codable, Equatable, Sendable {
    var segmentId: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var confidence: Double
}

struct LocalPipelineBaseChunkOutput: Codable, Equatable, Sendable {
    var chunkId: String
    var engineType: String
    var baseModel: String
    var language: String
    var segments: [LocalPipelineBaseSegment]
}

struct LocalPipelineDraftSegment: Codable, Equatable, Sendable {
    var segmentId: String
    var chunkId: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var sourceSegmentIDs: [String]
    var referenceSourceKind: LyricsReferenceSourceKind? = nil
    var alignmentSearchStart: TimeInterval? = nil
    var alignmentSearchEnd: TimeInterval? = nil
}

struct LocalPipelineDraftOutput: Codable, Equatable, Sendable {
    var runId: String
    var engineType: String
    var sourceFileName: String
    var baseModel: String
    var segments: [LocalPipelineDraftSegment]
}

struct LocalPipelineAlignedSegment: Codable, Equatable, Sendable {
    var segmentId: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct LocalPipelineSegmentAlignmentOutput: Codable, Equatable, Sendable {
    var runId: String
    var engineType: String
    var modelName: String
    var segments: [LocalPipelineAlignedSegment]
}

struct LocalPipelineCorrectionRecord: Codable, Equatable, Sendable {
    var type: String
    var before: String
    var after: String
}

struct LocalPipelineCorrectedSegment: Codable, Equatable, Sendable {
    var id: String
    var segmentId: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var baseTranscript: String
    var finalTranscript: String
    var corrections: [LocalPipelineCorrectionRecord]
}

struct LocalPipelineFinalOutput: Codable, Equatable, Sendable {
    var runId: String
    var engineType: String
    var sourceFileName: String
    var baseModel: String
    var alignmentModel: String
    var segments: [LocalPipelineCorrectedSegment]
}

struct LocalPipelineAssemblyResult: Sendable {
    var subtitles: [SubtitleItem]
    var finalOutput: LocalPipelineFinalOutput
}
