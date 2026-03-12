import SwiftUI
import UniformTypeIdentifiers

struct SRTDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.subtitleStudioSRT] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    static let subtitleStudioSRT = UTType(filenameExtension: "srt") ?? .plainText
}
