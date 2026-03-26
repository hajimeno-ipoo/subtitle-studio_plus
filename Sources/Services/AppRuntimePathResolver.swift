import Foundation

struct AppRuntimePathResolver: @unchecked Sendable {
    private let fileManager: FileManager
    private let bundle: Bundle
    private let environment: [String: String]
    private let projectRootOverride: URL?
    private let appSupportBaseOverride: URL?

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projectRootOverride: URL? = nil,
        appSupportBaseOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.environment = environment
        self.projectRootOverride = projectRootOverride
        self.appSupportBaseOverride = appSupportBaseOverride
    }

    func candidateURLs(forResourcePath rawPath: String) -> [URL] {
        guard let expanded = normalizedPath(rawPath) else { return [] }
        if expanded.hasPrefix("/") {
            return [URL(fileURLWithPath: expanded)]
        }

        return deduplicated(resourceBaseDirectories().map { baseURL in
            baseURL.appendingPathComponent(expanded)
        })
    }

    func candidateExecutableURLs(for rawPath: String) -> [URL] {
        guard let expanded = normalizedPath(rawPath) else { return [] }
        if expanded.hasPrefix("/") {
            return [URL(fileURLWithPath: expanded)]
        }

        var candidates = candidateURLs(forResourcePath: expanded)
        let executableName = URL(fileURLWithPath: expanded).lastPathComponent

        if executableName == "whisper-cli" {
            candidates.append(contentsOf: pathExecutableCandidates(named: executableName))
            candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"))
            candidates.append(URL(fileURLWithPath: "/usr/local/bin/whisper-cli"))
        }

        if executableName == "python3" || executableName == "python" {
            candidates.append(contentsOf: managedPythonExecutableCandidates())
            candidates.append(contentsOf: pathExecutableCandidates(named: executableName))
            candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/python3"))
            candidates.append(URL(fileURLWithPath: "/usr/local/bin/python3"))
        }

        return deduplicated(candidates)
    }

    func candidateWhisperModelURLs(for baseModel: LocalBaseModel) -> [URL] {
        let fileName: String
        switch baseModel {
        case .kotobaWhisperV2:
            fileName = "ggml-kotoba-whisper-v2.0.bin"
        case .kotobaWhisperBilingual:
            fileName = "ggml-kotoba-whisper-bilingual-v1.0.bin"
        }

        return deduplicated(managedModelDirectories().map { directoryURL in
            directoryURL.appendingPathComponent(fileName)
        })
    }

    func resolveOutputDirectory(_ rawPath: String) -> URL {
        let expanded = normalizedPath(rawPath, defaultValue: "Work")!
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        if let projectRootURL = existingProjectRootURL() {
            return projectRootURL.appendingPathComponent(expanded, isDirectory: true)
        }

        return applicationSupportBaseURL().appendingPathComponent(expanded, isDirectory: true)
    }

    private func resourceBaseDirectories() -> [URL] {
        var baseDirectories: [URL] = []

        if let resourceURL = bundle.resourceURL {
            baseDirectories.append(resourceURL)
        }

        if let projectRootURL = existingProjectRootURL() {
            baseDirectories.append(projectRootURL)
        }

        return deduplicated(baseDirectories)
    }

    private func existingProjectRootURL() -> URL? {
        if let projectRootOverride {
            return fileManager.fileExists(atPath: projectRootOverride.path) ? projectRootOverride : nil
        }

        var currentURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let projectFileURL = currentURL.appendingPathComponent("SubtitleStudioPlus.xcodeproj")
            if fileManager.fileExists(atPath: projectFileURL.path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return nil
            }
            currentURL = parentURL
        }
    }

    private func applicationSupportBaseURL() -> URL {
        if let appSupportBaseOverride {
            return appSupportBaseOverride
        }

        if let baseURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return baseURL.appendingPathComponent("SubtitleStudioPlus", isDirectory: true)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SubtitleStudioPlus", isDirectory: true)
    }

    private func managedPythonExecutableCandidates() -> [URL] {
        let appSupportURL = applicationSupportBaseURL()
        let managedBinDirectories = [
            appSupportURL.appendingPathComponent("aeneas-venv/bin", isDirectory: true),
            appSupportURL.appendingPathComponent("aeneas/.venv/bin", isDirectory: true)
        ]

        return managedBinDirectories.flatMap { directoryURL in
            [
                directoryURL.appendingPathComponent("python3"),
                directoryURL.appendingPathComponent("python")
            ]
        }
    }

    private func managedModelDirectories() -> [URL] {
        let appSupportModelsURL = applicationSupportBaseURL().appendingPathComponent("Models", isDirectory: true)
        let homeModelsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Models/subtitle-studio-plus", isDirectory: true)

        return deduplicated([appSupportModelsURL, homeModelsURL])
    }

    private func pathExecutableCandidates(named executableName: String) -> [URL] {
        let pathValue = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        return pathValue.split(separator: ":").map { component in
            URL(fileURLWithPath: String(component), isDirectory: true)
                .appendingPathComponent(executableName)
        }
    }

    private func normalizedPath(_ rawPath: String, defaultValue: String? = nil) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? defaultValue : trimmed
        guard let candidate, !candidate.isEmpty else { return nil }
        return NSString(string: candidate).expandingTildeInPath
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var deduplicatedURLs: [URL] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            deduplicatedURLs.append(url)
        }

        return deduplicatedURLs
    }
}
