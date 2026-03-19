import Foundation
import UniformTypeIdentifiers

struct SubtitleItem: Identifiable, Equatable, Codable {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

enum ProcessingStatus: String, Codable {
    case idle
    case analyzing
    case completed
    case error
    case aligning
}

enum AnalysisPhase: String, Codable {
    case idle
    case loadingAudio
    case optimizingAudio
    case chunking
    case requestingChunk
    case parsingChunk
    case mergingChunks
    case completed
    case failed
}

struct AnalysisProgress: Equatable, Codable {
    var phase: AnalysisPhase
    var message: String
    var actualPercent: Double
    var displayPercent: Double
    var currentChunk: Int
    var totalChunks: Int

    init(
        phase: AnalysisPhase,
        message: String,
        actualPercent: Double,
        displayPercent: Double,
        currentChunk: Int = 0,
        totalChunks: Int = 0
    ) {
        self.phase = phase
        self.message = message
        self.actualPercent = actualPercent
        self.displayPercent = displayPercent
        self.currentChunk = currentChunk
        self.totalChunks = totalChunks
    }
}

struct AudioAsset: Equatable {
    var url: URL
    var fileName: String
    var duration: TimeInterval
    var fileSize: Int64
    var contentType: UTType?
}

struct TimelineViewport: Equatable {
    var zoom: CGFloat = 100
    var volume: Double = 1.0
    var isMuted = false
}

struct AppDialogState: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case success
        case error
        case unsavedChanges
        case confirmReset
    }

    let id = UUID()
    var title: String
    var message: String
    var kind: Kind
}

struct UnsavedChangesState: Equatable {
    var hasUnsavedChanges = false
}


enum TimelineDragMode {
    case move
    case resizeLeft
    case resizeRight
    case seek
}

enum AudioImportIntent {
    case replace(URL)
}

enum SubtitleStudioError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAudioType
    case invalidResolveExportAudioType
    case fileTooLarge
    case unreadableAudio
    case emptyGeminiResponse
    case invalidSRTResponse
    case alignmentFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Gemini API key is missing."
        case .invalidAudioType:
            "Please choose a supported audio or video file."
        case .invalidResolveExportAudioType:
            "EXPORT FOR DAVINCI supports audio-only files: mp3, wav, ogg, m4a, flac, aac, wma."
        case .fileTooLarge:
            "File size exceeds the 100MB limit."
        case .unreadableAudio:
            "The app could not decode this audio file."
        case .emptyGeminiResponse:
            "Gemini did not return any subtitle text."
        case .invalidSRTResponse:
            "Gemini returned text that could not be parsed as SRT."
        case .alignmentFailed(let message):
            "Waveform alignment failed: \(message)"
        case .network(let message):
            message
        }
    }
}
