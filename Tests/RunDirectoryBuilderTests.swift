@testable import SubtitleStudioPlus
import Foundation
import Testing

struct RunDirectoryBuilderTests {
    private func makeSettings(outputDirectoryPath: String) -> LocalPipelineSettings {
        var settings = LocalPipelineSettings.productionDefault
        settings.outputDirectoryPath = outputDirectoryPath
        return settings
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    @Test
    func definesRunDirectoryStructure() throws {
        let tempDirectory = try makeTempDirectory()
        let builder = RunDirectoryBuilder(fileManager: .default)
        let settings = makeSettings(outputDirectoryPath: tempDirectory.path)

        let (layout, manifest) = try builder.build(
            sourceFileName: "input.wav",
            sourceDuration: 12.5,
            settings: settings,
            engineType: .localPipeline
        )

        #expect(layout.rootURL.path.hasPrefix(tempDirectory.path))
        #expect(isDirectory(layout.rootURL))
        #expect(isDirectory(layout.inputDirectoryURL))
        #expect(isDirectory(layout.chunksDirectoryURL))
        #expect(isDirectory(layout.alignmentInputDirectoryURL))
        #expect(isDirectory(layout.finalDirectoryURL))
        #expect(isDirectory(layout.logsDirectoryURL))
        #expect(manifest.runId.hasPrefix("run-"))
    }

    @Test
    func writesManifestAndRunLogArtifacts() throws {
        let tempDirectory = try makeTempDirectory()
        let builder = RunDirectoryBuilder(fileManager: .default)
        let settings = makeSettings(outputDirectoryPath: tempDirectory.path)

        let (layout, manifest) = try builder.build(
            sourceFileName: "song.wav",
            sourceDuration: 42,
            settings: settings,
            engineType: .localPipeline
        )

        let decoded = try builder.loadManifest(from: layout.manifestURL)
        #expect(decoded == manifest)
        #expect(FileManager.default.fileExists(atPath: layout.runLogURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.whisperStderrURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.aeneasStderrURL.path))
    }

    @Test
    func excludesAPIKeyFromRunArtifacts() throws {
        let tempDirectory = try makeTempDirectory()
        let builder = RunDirectoryBuilder(fileManager: .default)
        let settings = makeSettings(outputDirectoryPath: tempDirectory.path)

        let (layout, _) = try builder.build(
            sourceFileName: "input.wav",
            sourceDuration: 1,
            settings: settings,
            engineType: .localPipeline
        )

        let manifestText = try String(contentsOf: layout.manifestURL, encoding: .utf8)
        let runLogText = try String(contentsOf: layout.runLogURL, encoding: .utf8)

        #expect(!manifestText.contains("geminiAPIKey"))
        #expect(!manifestText.contains("apiKey"))
        #expect(!runLogText.contains("geminiAPIKey"))
        #expect(!runLogText.contains("apiKey"))
    }

    @Test
    func relativeOutputDirectoryFallsBackToApplicationSupportBase() throws {
        let tempDirectory = try makeTempDirectory()
        let appSupportBase = tempDirectory.appendingPathComponent("AppSupport", isDirectory: true)
        let resolver = AppRuntimePathResolver(
            fileManager: .default,
            projectRootOverride: tempDirectory.appendingPathComponent("missing-project-root", isDirectory: true),
            appSupportBaseOverride: appSupportBase
        )
        let builder = RunDirectoryBuilder(fileManager: .default, runtimePathResolver: resolver)
        let settings = makeSettings(outputDirectoryPath: "Work")

        let (layout, _) = try builder.build(
            sourceFileName: "fallback.wav",
            sourceDuration: 3,
            settings: settings,
            engineType: .localPipeline
        )

        #expect(layout.rootURL.path.hasPrefix(appSupportBase.appendingPathComponent("Work", isDirectory: true).path))
    }

    @Test
    func prunesOldRunDirectories() throws {
        let tempDirectory = try makeTempDirectory()
        let builder = RunDirectoryBuilder(fileManager: .default)
        let settings = makeSettings(outputDirectoryPath: tempDirectory.path)

        for index in 0..<10 {
            let runURL = tempDirectory.appendingPathComponent("run-20260321-00000\(index)-deadbeef", isDirectory: true)
            try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        }

        _ = try builder.build(
            sourceFileName: "song.wav",
            sourceDuration: 42,
            settings: settings,
            engineType: .localPipeline
        )

        let remainingRuns = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("run-") && isDirectory($0) }

        #expect(remainingRuns.count == 8)
    }

    @Test
    func scrubsIntermediateArtifactsFromRetainedRuns() throws {
        let tempDirectory = try makeTempDirectory()
        let retainedRunURL = tempDirectory.appendingPathComponent("run-20260321-000009-deadbeef", isDirectory: true)
        try FileManager.default.createDirectory(at: retainedRunURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("input", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("chunks", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("base_json", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("draft_json", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("alignment_input", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("aligned_json", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("final", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRunURL.appendingPathComponent("logs", isDirectory: true), withIntermediateDirectories: true)

        let builder = RunDirectoryBuilder(fileManager: .default)
        let settings = makeSettings(outputDirectoryPath: tempDirectory.path)

        _ = try builder.build(
            sourceFileName: "song.wav",
            sourceDuration: 42,
            settings: settings,
            engineType: .localPipeline
        )

        #expect(!FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("input").path))
        #expect(!FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("chunks").path))
        #expect(!FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("base_json").path))
        #expect(!FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("draft_json").path))
        #expect(!FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("alignment_input").path))
        #expect(!FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("aligned_json").path))
        #expect(FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("final").path))
        #expect(FileManager.default.fileExists(atPath: retainedRunURL.appendingPathComponent("logs").path))
    }
}
