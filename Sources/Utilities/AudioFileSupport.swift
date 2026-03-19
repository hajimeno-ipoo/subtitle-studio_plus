import Foundation
import UniformTypeIdentifiers

enum AudioFileSupport {
    static let supportedExtensions = Set(["mp3", "wav", "ogg", "m4a", "mp4", "webm", "flac", "aac", "wma"])
    static let resolveExportSupportedExtensions = Set(["mp3", "wav", "ogg", "m4a", "flac", "aac", "wma"])

    static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isResolveExportSupported(url: URL) -> Bool {
        resolveExportSupportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func supportedContentTypes() -> [UTType] {
        [.audio, .movie, .mpeg4Audio, .mp3, .wav]
    }
}
