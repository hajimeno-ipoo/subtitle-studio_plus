import Foundation

enum LocalPipelineServiceConfig {
    static let minimumStandaloneSubtitleDuration: TimeInterval = 0.35
    static let draftTargetDuration: TimeInterval = 4.8
    static let draftMaxDuration: TimeInterval = 7.5
    static let draftMaxLines = 2
    static let alignmentPadding: TimeInterval = 0.45
    static let alignmentTimeoutPerBlock: TimeInterval = 45
    static let preserveIntermediateArtifacts = false
    static let retryNoSpeechThreshold = 0.2
    static let rescueChunkOverlapSeconds: TimeInterval = 0.4
    static let preferredBaseSegmentDuration: TimeInterval = 4.2
    static let rescueChunkTargetDuration: TimeInterval = 3.0
    static let tokenSegmentTargetCharacters = 6
    static let tokenSegmentMaxCharacters = 8
    static let tokenSegmentHardMaxDuration: TimeInterval = 3.2
    static let tokenSegmentStrongGap: TimeInterval = 0.28
    static let tokenSegmentSoftGap: TimeInterval = 0.16
    static let referenceSRTSearchPad: TimeInterval = 0.6
    static let referenceSRTMaxShift: TimeInterval = 0.8
    static let referenceSRTAlignmentPadding: TimeInterval = 0.2
    static let txtGroupedAlignmentMaxLines = 2
    static let txtGroupedAlignmentMaxGap: TimeInterval = 0.45
    static let txtGroupedAlignmentMaxSpan: TimeInterval = 9.0
    static let txtSuspiciousClipEdgeTolerance: TimeInterval = 0.08
    static let txtSuspiciousClipCoverageRatio = 0.94
    static let txtSuspiciousClipExcessDuration: TimeInterval = 0.8
    static let txtReferenceTrimSearchPadding: TimeInterval = 0.35
    static let txtReferenceBoundaryWindowDuration: TimeInterval = 0.004
    static let txtReferenceBoundaryStepDuration: TimeInterval = 0.001
    static let txtReferenceEnergyWindowDuration: TimeInterval = 0.008
    static let txtReferenceEnergyStepDuration: TimeInterval = 0.002
    static let txtReferenceProtectedGapThreshold: TimeInterval = 0.75
    static let vadWindowSize: TimeInterval = 0.01
    static let vadMinGapFill: TimeInterval = 0.18
    static let vadMinRegionDuration: TimeInterval = 0.12
    static let vadMergeGap: TimeInterval = 0.2
    static let txtReferenceSpeechMergeGap: TimeInterval = 0.7
    static let txtAlignmentPadding: TimeInterval = 1.2
    static let txtAeneasMaxShift: TimeInterval = 0.6
    static let referenceDraftMaxOverlap: TimeInterval = 0.12
    static let unmatchedLinePenalty = 3.4
    static let skippedRegionPenalty = 1.3
    static let aeneasMaxShift: TimeInterval = 2.5
    static let localWaveformAlignmentConfig = AlignmentConfig(
        searchWindowPad: 2.0,
        rmsWindowSize: 0.005,
        thresholdRatio: 0.12,
        minVolumeAbsolute: 0.002,
        padStart: 0.15,
        padEnd: 0.25,
        maxSnapDistance: 1.0,
        minGapFill: 0.3,
        useAdaptiveThreshold: true
    )
    static let whisperBasePrompt = """
日本語の歌詞です。
字幕風ではなく、自然な歌詞として認識してください。
意味の通る語のまとまりを優先し、不自然な語の分割を避けてください。
聞こえない部分を創作せず、曖昧な箇所はそのまま控えめに出してください。
文字化けした記号や不正な文字は出力しないでください。
"""
}

struct ResolvedPaths {
    var pythonExecutableURL: URL
    var whisperModelURL: URL
    var whisperCoreMLModelURL: URL?
    var aeneasScriptURL: URL
}

struct AlignmentInputSegment: Codable {
    var segmentId: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var audioPath: String
    var clipStartTime: TimeInterval
    var lineSegmentIDs: [String]? = nil
    var lineTexts: [String]? = nil
    var lineStartTimes: [TimeInterval]? = nil
    var lineEndTimes: [TimeInterval]? = nil
    var lineSearchStartTimes: [TimeInterval]? = nil
    var lineSearchEndTimes: [TimeInterval]? = nil
}

struct AlignmentInputManifest: Codable {
    var runId: String
    var sourceFileName: String
    var language: String
    var segments: [AlignmentInputSegment]
}

struct WhisperTokenPiece {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var confidence: Double
}

struct SpeechRegion: Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

struct GuideRegion: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var sourceSegmentIDs: [String]
}

struct TimingGuideAnchor {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var confidence: Double
    var sourceSegmentIDs: [String]
}

struct ReferenceAlignmentMatch {
    var entry: ReferenceLyricEntry
    var region: GuideRegion?
    var wasUnmatched: Bool
}

struct AlignmentState {
    var cost: Double
    var lastMatchedEnd: TimeInterval?
}

struct AlignmentRejectionReason {
    var segmentId: String
    var reason: String
    var startDelta: TimeInterval
    var endDelta: TimeInterval
}

struct SanitizedAlignmentResult {
    var accepted: [LocalPipelineAlignedSegment]
    var rejected: [AlignmentRejectionReason]
}

actor AlignmentProgressTracker {
    private var buffer = ""
    private let totalBlocks: Int
    private let progress: @Sendable (LocalPipelineProgress) async -> Void

    init(
        totalBlocks: Int,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) {
        self.totalBlocks = max(totalBlocks, 1)
        self.progress = progress
    }

    func consume(_ data: Data) async {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        buffer.append(text)

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            await handle(line)
        }
    }

    private func handle(_ line: String) async {
        guard let marker = line.range(of: "Aligning block ") else { return }
        let suffix = line[marker.upperBound...]
        guard let colonIndex = suffix.firstIndex(of: ":") else { return }
        let fraction = suffix[..<colonIndex]
        let parts = fraction.split(separator: "/")
        guard parts.count == 2,
              let current = Int(parts[0]),
              let total = Int(parts[1]),
              total > 0 else {
            return
        }

        let safeTotal = max(totalBlocks, total)
        let ratio = Double(min(current, safeTotal)) / Double(safeTotal)
        await progress(
            LocalPipelineProgress(
                phase: .aligning,
                message: "解析中...",
                currentChunk: min(current, safeTotal),
                totalChunks: safeTotal,
                displayPercent: 60 + ratio * 25
            )
        )
    }
}
