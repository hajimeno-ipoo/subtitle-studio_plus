import Foundation
import UniformTypeIdentifiers

struct SubtitleItem: Identifiable, Equatable, Codable, Sendable {
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

enum SRTGenerationEngine: String, Codable, CaseIterable, Sendable {
    case gemini
    case localPipeline
}

enum LocalBaseModel: String, Codable, CaseIterable, Sendable {
    case kotobaWhisperV2
    case kotobaWhisperV22
    case kotobaWhisperBilingual
}

struct LocalPipelineSettings: Codable, Equatable, Sendable {
    var baseModel: LocalBaseModel
    var language: String
    var initialPrompt: String
    var chunkLengthSeconds: Double
    var overlapSeconds: Double
    var temperature: Double
    var beamSize: Int
    var noSpeechThreshold: Double
    var logprobThreshold: Double
    var whisperModelPath: String
    var whisperCoreMLModelPath: String
    var aeneasPythonPath: String
    var aeneasScriptPath: String
    var correctionDictionaryPath: String
    var knownLyricsPath: String
    var outputDirectoryPath: String

    static let productionDefault = LocalPipelineSettings(
        baseModel: .kotobaWhisperV2,
        language: "ja",
        initialPrompt: "",
        chunkLengthSeconds: 8.0,
        overlapSeconds: 1.0,
        temperature: 0.0,
        beamSize: 5,
        noSpeechThreshold: 0.6,
        logprobThreshold: -1.0,
        whisperModelPath: "",
        whisperCoreMLModelPath: "",
        aeneasPythonPath: "python3",
        aeneasScriptPath: "Tools/aeneas/align_subtitles.py",
        correctionDictionaryPath: "Tools/dictionaries/default_ja_corrections.json",
        knownLyricsPath: "Tools/dictionaries/sample_known_lyrics.txt",
        outputDirectoryPath: "Work"
    )
}

enum LocalPipelinePhase: String, Codable, Sendable {
    case validating
    case preparing
    case chunking
    case baseTranscribing
    case aligning
    case correcting
    case assembling
    case writingOutputs
}

struct LocalPipelineProgress: Codable, Equatable, Sendable {
    var phase: LocalPipelinePhase
    var message: String
    var currentChunk: Int
    var totalChunks: Int
    var displayPercent: Double
}

struct LocalPipelineResult: Sendable {
    var subtitles: [SubtitleItem]
    var runDirectoryURL: URL
    var finalSRTURL: URL
}

protocol LocalPipelineAnalyzing: Sendable {
    func analyze(
        fileURL: URL,
        settings: LocalPipelineSettings,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> LocalPipelineResult
}

protocol ExternalProcessRunning: Sendable {
    func run(_ request: ExternalProcessRequest) async throws -> ExternalProcessResult
}

struct ExternalProcessRequest: Sendable {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: URL?
    var environment: [String: String]
    var timeout: TimeInterval
    var onStderrChunk: (@Sendable (Data) async -> Void)? = nil
}

struct ExternalProcessResult: Sendable {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32
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
    case localPipelineUnavailable
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
        case .localPipelineUnavailable:
            "Local Pipeline is not configured yet."
        case .network(let message):
            message
        }
    }
}

enum LocalPipelineError: LocalizedError, Equatable {
    case missingExecutable(String)
    case missingModelFile(String)
    case invalidConfiguration(String)
    case normalizationFailed(String)
    case chunkingFailed(String)
    case baseTranscriptionFailed(String)
    case emptyTranscription(String)
    case alignmentFailed(String)
    case correctionFailed(String)
    case invalidJSON(String)
    case outputWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            "Missing executable: \(path)"
        case .missingModelFile(let path):
            "Missing model file: \(path)"
        case .invalidConfiguration(let message):
            "Invalid local pipeline configuration: \(message)"
        case .normalizationFailed(let message):
            "Normalization failed: \(message)"
        case .chunkingFailed(let message):
            "Chunking failed: \(message)"
        case .baseTranscriptionFailed(let message):
            "Base transcription failed: \(message)"
        case .emptyTranscription(let message):
            "Empty transcription: \(message)"
        case .alignmentFailed(let message):
            "Forced alignment failed: \(message)"
        case .correctionFailed(let message):
            "Correction failed: \(message)"
        case .invalidJSON(let message):
            "Invalid JSON: \(message)"
        case .outputWriteFailed(let message):
            "Output write failed: \(message)"
        }
    }
}
