import Foundation

enum RunLogLevel: String, Codable, Sendable {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

struct RunLogLine: Codable, Equatable, Sendable {
    var timestamp: String
    var runId: String
    var stage: String
    var level: String
    var message: String
    var engineType: String
    var chunkId: String?
    var command: String?
    var exitCode: Int32?
    var stderrPath: String?
}

struct RunLogger: Sendable {
    let logURL: URL

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func log(
        runId: String,
        stage: String,
        level: RunLogLevel,
        message: String,
        engineType: SRTGenerationEngine,
        chunkId: String? = nil,
        command: String? = nil,
        exitCode: Int32? = nil,
        stderrPath: URL? = nil
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        let timestamp = formatter.string(from: Date())
        let entry = RunLogLine(
            timestamp: timestamp,
            runId: runId,
            stage: stage,
            level: level.rawValue,
            message: message,
            engineType: engineType.rawValue,
            chunkId: chunkId,
            command: command,
            exitCode: exitCode,
            stderrPath: stderrPath?.path
        )
        try append(entry)
    }

    func append(_ entry: RunLogLine) throws {
        let data = try encoder.encode(entry)
        try ensureLogFileExists()
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private func ensureLogFileExists() throws {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: nil)
        }
    }
}
