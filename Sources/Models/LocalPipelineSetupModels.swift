import Foundation

enum LocalPipelineSetupState: Equatable, Sendable {
    case checking
    case ready(String)
    case missing(String)
    case inProgress(String)
    case failed(String)

    var message: String {
        switch self {
        case .checking:
            return "確認中です。"
        case .ready(let message),
             .missing(let message),
             .inProgress(let message),
             .failed(let message):
            return message
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

enum LocalPipelineSetupAction: Equatable, Sendable {
    case downloadWhisperModel
    case downloadCoreMLModel
    case installAlignmentTools
    case openPythonGuide
    case openFFmpegGuide
}

struct LocalPipelineSetupRowStatus: Equatable, Sendable {
    var state: LocalPipelineSetupState
    var action: LocalPipelineSetupAction?

    static let checking = LocalPipelineSetupRowStatus(state: .checking, action: nil)
}

struct LocalPipelineSetupStatus: Equatable, Sendable {
    var overall: LocalPipelineSetupState
    var whisperModel: LocalPipelineSetupRowStatus
    var python: LocalPipelineSetupRowStatus
    var ffmpeg: LocalPipelineSetupRowStatus
    var aeneas: LocalPipelineSetupRowStatus
    var coreML: LocalPipelineSetupRowStatus
    var ffprobe: LocalPipelineSetupRowStatus
    var espeak: LocalPipelineSetupRowStatus
    var supportFiles: LocalPipelineSetupRowStatus
    var note: String

    static let checking = LocalPipelineSetupStatus(
        overall: .checking,
        whisperModel: .checking,
        python: .checking,
        ffmpeg: .checking,
        aeneas: .checking,
        coreML: .checking,
        ffprobe: .checking,
        espeak: .checking,
        supportFiles: .checking,
        note: "高速化用 Core ML モデルは任意です。今回は自動取得の対象外です。"
    )
}

enum LocalPipelineManagedAsset: String, CaseIterable, Sendable {
    case kotobaWhisperV2
    case kotobaWhisperBilingual

    init(baseModel: LocalBaseModel) {
        switch baseModel {
        case .kotobaWhisperV2:
            self = .kotobaWhisperV2
        case .kotobaWhisperBilingual:
            self = .kotobaWhisperBilingual
        }
    }

    var displayName: String {
        switch self {
        case .kotobaWhisperV2:
            return "Kotoba Whisper v2.0"
        case .kotobaWhisperBilingual:
            return "Kotoba Whisper Bilingual v1.0"
        }
    }

    var fileName: String {
        switch self {
        case .kotobaWhisperV2:
            return "ggml-kotoba-whisper-v2.0.bin"
        case .kotobaWhisperBilingual:
            return "ggml-kotoba-whisper-bilingual-v1.0.bin"
        }
    }

    var downloadURL: URL {
        switch self {
        case .kotobaWhisperV2:
            return URL(string: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0.bin?download=true")!
        case .kotobaWhisperBilingual:
            return URL(string: "https://huggingface.co/kotoba-tech/kotoba-whisper-bilingual-v1.0-ggml/resolve/main/ggml-kotoba-whisper-bilingual-v1.0.bin?download=true")!
        }
    }
}

enum LocalPipelineSetupError: LocalizedError, Equatable {
    case pythonNotFound
    case setupPrerequisiteMissing(String)
    case commandFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "Python が見つかりませんでした。先に Python 3 を入れてください。"
        case .setupPrerequisiteMissing(let message):
            return message
        case .commandFailed(let message):
            return message
        case .downloadFailed(let message):
            return message
        }
    }
}
