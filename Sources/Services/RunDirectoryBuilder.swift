import Foundation

enum RunManifestStage: String, Codable, CaseIterable, Sendable {
    case normalized
    case chunked
    case baseTranscribed
    case aligned
    case corrected
    case outputsWritten
}

struct RunManifestSettingsSnapshot: Codable, Equatable, Sendable {
    var baseModel: LocalBaseModel
    var language: String
    var chunkLengthSeconds: Double
    var overlapSeconds: Double
}

struct RunManifestStages: Codable, Equatable, Sendable {
    var normalized = false
    var chunked = false
    var baseTranscribed = false
    var aligned = false
    var corrected = false
    var outputsWritten = false
}

struct RunDirectoryManifest: Codable, Equatable, Sendable {
    var runId: String
    var engineType: SRTGenerationEngine
    var sourceFileName: String
    var sourceDuration: TimeInterval
    var settingsSnapshot: RunManifestSettingsSnapshot
    var stages: RunManifestStages
    var resumeFrom: String?
}

struct RunDirectoryLayout: Sendable {
    var rootURL: URL
    var manifestURL: URL
    var inputDirectoryURL: URL
    var chunksDirectoryURL: URL
    var alignmentInputDirectoryURL: URL
    var finalDirectoryURL: URL
    var logsDirectoryURL: URL
    var runLogURL: URL
    var whisperStderrURL: URL
    var aeneasStderrURL: URL
}

struct RunDirectoryBuilder {
    private static let retainedRunDirectoryCount = 8
    private let fileManager: FileManager
    private let runtimePathResolver: AppRuntimePathResolver
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileManager: FileManager = .default,
        runtimePathResolver: AppRuntimePathResolver = AppRuntimePathResolver()
    ) {
        self.fileManager = fileManager
        self.runtimePathResolver = runtimePathResolver
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func build(
        sourceFileName: String,
        sourceDuration: TimeInterval,
        settings: LocalPipelineSettings,
        engineType: SRTGenerationEngine,
        resumeFrom: String? = nil
    ) throws -> (layout: RunDirectoryLayout, manifest: RunDirectoryManifest) {
        let runId = makeRunID()
        let baseOutputDirectory = resolveBaseOutputDirectory(settings.outputDirectoryPath)
        try createDirectory(at: baseOutputDirectory)
        try pruneOldRunDirectories(
            in: baseOutputDirectory,
            keeping: max(Self.retainedRunDirectoryCount - 1, 0)
        )
        try scrubIntermediateArtifacts(in: baseOutputDirectory)
        let rootURL = baseOutputDirectory.appendingPathComponent(runId, isDirectory: true)
        let inputDirectoryURL = rootURL.appendingPathComponent("input", isDirectory: true)
        let chunksDirectoryURL = rootURL.appendingPathComponent("chunks", isDirectory: true)
        let alignmentInputDirectoryURL = rootURL.appendingPathComponent("alignment_input", isDirectory: true)
        let finalDirectoryURL = rootURL.appendingPathComponent("final", isDirectory: true)
        let logsDirectoryURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let runLogURL = logsDirectoryURL.appendingPathComponent("run.jsonl")
        let whisperStderrURL = logsDirectoryURL.appendingPathComponent("whisper.stderr.log")
        let aeneasStderrURL = logsDirectoryURL.appendingPathComponent("aeneas.stderr.log")

        try createDirectory(at: rootURL)
        try createDirectory(at: inputDirectoryURL)
        try createDirectory(at: chunksDirectoryURL)
        try createDirectory(at: alignmentInputDirectoryURL)
        try createDirectory(at: finalDirectoryURL)
        try createDirectory(at: logsDirectoryURL)

        try ensureFile(at: runLogURL)
        try ensureFile(at: whisperStderrURL)
        try ensureFile(at: aeneasStderrURL)

        let manifest = RunDirectoryManifest(
            runId: runId,
            engineType: engineType,
            sourceFileName: sourceFileName,
            sourceDuration: sourceDuration,
            settingsSnapshot: RunManifestSettingsSnapshot(
                baseModel: settings.baseModel,
                language: settings.language,
                chunkLengthSeconds: settings.chunkLengthSeconds,
                overlapSeconds: settings.overlapSeconds
            ),
            stages: RunManifestStages(),
            resumeFrom: resumeFrom
        )
        try writeManifest(manifest, to: manifestURL)

        return (
            RunDirectoryLayout(
                rootURL: rootURL,
                manifestURL: manifestURL,
                inputDirectoryURL: inputDirectoryURL,
                chunksDirectoryURL: chunksDirectoryURL,
                alignmentInputDirectoryURL: alignmentInputDirectoryURL,
                finalDirectoryURL: finalDirectoryURL,
                logsDirectoryURL: logsDirectoryURL,
                runLogURL: runLogURL,
                whisperStderrURL: whisperStderrURL,
                aeneasStderrURL: aeneasStderrURL
            ),
            manifest
        )
    }

    func loadManifest(from url: URL) throws -> RunDirectoryManifest {
        let data = try Data(contentsOf: url)
        return try decoder.decode(RunDirectoryManifest.self, from: data)
    }

    func writeManifest(_ manifest: RunDirectoryManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    func markStage(
        _ stage: RunManifestStage,
        manifest: inout RunDirectoryManifest,
        at url: URL
    ) throws {
        switch stage {
        case .normalized:
            manifest.stages.normalized = true
        case .chunked:
            manifest.stages.chunked = true
        case .baseTranscribed:
            manifest.stages.baseTranscribed = true
        case .aligned:
            manifest.stages.aligned = true
        case .corrected:
            manifest.stages.corrected = true
        case .outputsWritten:
            manifest.stages.outputsWritten = true
        }
        try writeManifest(manifest, to: url)
    }

    private func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.calendar = .init(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "run-\(timestamp)-\(suffix)"
    }

    private func resolveBaseOutputDirectory(_ rawPath: String) -> URL {
        runtimePathResolver.resolveOutputDirectory(rawPath)
    }

    private func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func ensureFile(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data(), attributes: nil)
            return
        }
        if fileManager.isDirectory(atPath: url.path) {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private func pruneOldRunDirectories(in baseDirectoryURL: URL, keeping count: Int) throws {
        guard count >= 0 else { return }

        let runDirectories = try fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent.hasPrefix("run-") && fileManager.isDirectory(atPath: url.path)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let overflow = runDirectories.count - count
        guard overflow > 0 else { return }

        for url in runDirectories.prefix(overflow) {
            try fileManager.removeItem(at: url)
        }
    }

    private func scrubIntermediateArtifacts(in baseDirectoryURL: URL) throws {
        let runDirectories = try fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent.hasPrefix("run-") && fileManager.isDirectory(atPath: url.path)
        }

        let removableNames = [
            "input",
            "chunks",
            "base_json",
            "draft_json",
            "alignment_input",
            "aligned_json"
        ]

        for runURL in runDirectories {
            for name in removableNames {
                let artifactURL = runURL.appendingPathComponent(name, isDirectory: true)
                guard fileManager.fileExists(atPath: artifactURL.path) else { continue }
                try? fileManager.removeItem(at: artifactURL)
            }
        }
    }
}

private extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }
}
