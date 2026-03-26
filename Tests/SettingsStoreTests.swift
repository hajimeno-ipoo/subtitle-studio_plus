@testable import SubtitleStudioPlus
import Foundation
import Testing

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loadCount = 0
    private(set) var savedValues: [String] = []

    func recordLoad() {
        lock.lock()
        loadCount += 1
        lock.unlock()
    }

    func recordSave(_ value: String) {
        lock.lock()
        savedValues.append(value)
        lock.unlock()
    }
}

private func waitUntil(
    timeout: TimeInterval = 1.0,
    predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() {
            return true
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
struct SettingsStoreTests {
    private func makeDefaults(suffix: String = UUID().uuidString) -> UserDefaults {
        let suiteName = "SettingsStoreTests.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(
        loadKeychain: @escaping @Sendable () -> String,
        saveKeychain: @escaping @Sendable (String) -> Void,
        userDefaults: UserDefaults
    ) -> SettingsStore {
        SettingsStore(
            loadKeychain: loadKeychain,
            saveKeychain: saveKeychain,
            userDefaults: userDefaults
        )
    }

    @Test
    func loadIfNeededRunsOffMainAndOnlyOnce() async {
        let counter = CounterBox()
        let defaults = makeDefaults()
        let store = await makeStore(
            loadKeychain: {
                counter.recordLoad()
                Thread.sleep(forTimeInterval: 0.05)
                return "abc123"
            },
            saveKeychain: { _ in },
            userDefaults: defaults
        )

        let task = Task { await store.loadIfNeeded() }
        #expect(await waitUntil { await MainActor.run { store.isLoadingAPIKey } })

        await task.value
        #expect(await MainActor.run { store.geminiAPIKey == "abc123" })
        #expect(await MainActor.run { store.isLoadingAPIKey == false })
        #expect(counter.loadCount == 1)

        await store.loadIfNeeded()
        #expect(counter.loadCount == 1)
    }

    @Test
    func persistTrimsValueAndResetsBusyFlag() async {
        let counter = CounterBox()
        let defaults = makeDefaults()
        let store = await makeStore(
            loadKeychain: { "" },
            saveKeychain: {
                counter.recordSave($0)
                Thread.sleep(forTimeInterval: 0.05)
            },
            userDefaults: defaults
        )

        let task = Task { await store.persist("  my-key  ") }
        #expect(await waitUntil { await MainActor.run { store.isSavingAPIKey } })

        await task.value
        #expect(await MainActor.run { store.isSavingAPIKey == false })
        #expect(await MainActor.run { store.geminiAPIKey == "my-key" })
        #expect(counter.savedValues == ["my-key"])
    }

    @Test
    func localPipelineSettingsAndEnginePersistToUserDefaults() async {
        let defaults = makeDefaults()
        let first = await makeStore(
            loadKeychain: { "" },
            saveKeychain: { _ in },
            userDefaults: defaults
        )

        await first.loadIfNeeded()
        await MainActor.run {
            first.selectedSRTGenerationEngine = .localPipeline
            first.markLocalPipelineBaseModelCustomized()
            first.localPipelineSettings.baseModel = .kotobaWhisperBilingual
            first.localPipelineSettings.initialPrompt = "hook phrase"
            first.localPipelineSettings.chunkLengthSeconds = 12.5
            first.localPipelineSettings.aeneasPythonPath = "/opt/homebrew/bin/python3"
            first.autoAlignUseAdaptiveThreshold = false
        }

        let second = await makeStore(
            loadKeychain: { "" },
            saveKeychain: { _ in },
            userDefaults: defaults
        )
        await second.loadIfNeeded()

        #expect(await MainActor.run { second.selectedSRTGenerationEngine == .localPipeline })
        #expect(await MainActor.run { second.localPipelineSettings.baseModel == .kotobaWhisperBilingual })
        #expect(await MainActor.run { second.localPipelineSettings.initialPrompt == "hook phrase" })
        #expect(await MainActor.run { second.localPipelineSettings.chunkLengthSeconds == 12.5 })
        #expect(await MainActor.run { second.localPipelineSettings.aeneasPythonPath == "/opt/homebrew/bin/python3" })
        #expect(await MainActor.run { second.autoAlignUseAdaptiveThreshold == false })
    }

    @Test
    func recommendedBaseModelUsesFileNameHeuristicUntilCustomized() async {
        let defaults = makeDefaults()
        let store = await makeStore(
            loadKeychain: { "" },
            saveKeychain: { _ in },
            userDefaults: defaults
        )

        await store.loadIfNeeded()
        await MainActor.run {
            store.applyRecommendedLocalBaseModelIfNeeded(for: "Artist - English Song.wav")
        }
        #expect(await MainActor.run { store.localPipelineSettings.baseModel == .kotobaWhisperBilingual })

        await MainActor.run {
            store.markLocalPipelineBaseModelCustomized()
            store.localPipelineSettings.baseModel = .kotobaWhisperV2
            store.applyRecommendedLocalBaseModelIfNeeded(for: "Artist - Another English Song.wav")
        }
        #expect(await MainActor.run { store.localPipelineSettings.baseModel == .kotobaWhisperV2 })
    }

    @Test
    func invalidEngineAndCorruptedLocalSettingsFallBackToDefaults() async {
        let defaults = makeDefaults()
        defaults.set("unsupported-engine", forKey: "selectedSRTGenerationEngine")
        defaults.set(Data("broken".utf8), forKey: "localPipelineSettings")

        let store = await makeStore(
            loadKeychain: { "" },
            saveKeychain: { _ in },
            userDefaults: defaults
        )
        await store.loadIfNeeded()

        #expect(await MainActor.run { store.selectedSRTGenerationEngine == .gemini })
        #expect(await MainActor.run { store.localPipelineSettings == .productionDefault })
    }

    @Test
    func legacyLocalPipelineSettingsWithWhisperCLIPathStillDecode() async {
        let defaults = makeDefaults()
        defaults.set(
            Data(
                """
                {
                  "baseModel": "kotobaWhisperV2",
                  "language": "ja",
                  "initialPrompt": "legacy prompt",
                  "chunkLengthSeconds": 8,
                  "overlapSeconds": 1,
                  "temperature": 0,
                  "beamSize": 5,
                  "noSpeechThreshold": 0.6,
                  "logprobThreshold": -1,
                  "whisperCLIPath": "/opt/homebrew/bin/whisper-cli",
                  "whisperModelPath": "/tmp/model.bin",
                  "whisperCoreMLModelPath": "",
                  "aeneasPythonPath": "python3",
                  "aeneasScriptPath": "Tools/aeneas/align_subtitles.py",
                  "correctionDictionaryPath": "Tools/dictionaries/default_ja_corrections.json",
                  "knownLyricsPath": "Tools/dictionaries/sample_known_lyrics.txt",
                  "outputDirectoryPath": "Work"
                }
                """.utf8
            ),
            forKey: "localPipelineSettings"
        )

        let store = await makeStore(
            loadKeychain: { "" },
            saveKeychain: { _ in },
            userDefaults: defaults
        )
        await store.loadIfNeeded()

        #expect(await MainActor.run { store.localPipelineSettings.baseModel == .kotobaWhisperV2 })
        #expect(await MainActor.run { store.localPipelineSettings.initialPrompt == "legacy prompt" })
        #expect(await MainActor.run { store.localPipelineSettings.aeneasPythonPath == "python3" })
    }

    @Test
    func settingsStoreDefinesEngineAndLocalPipelinePersistenceContract() async {
        let defaults = makeDefaults()
        let store = await makeStore(
            loadKeychain: { "" },
            saveKeychain: { _ in },
            userDefaults: defaults
        )

        await store.loadIfNeeded()

        #expect(await MainActor.run { store.selectedSRTGenerationEngine == .gemini })
        #expect(await MainActor.run { store.localPipelineSettings == .productionDefault })
        #expect(await MainActor.run { store.autoAlignUseAdaptiveThreshold == true })
    }

    @Test
    func appModelsDefineLocalPipelinePublicTypes() {
        #expect(SRTGenerationEngine.gemini.rawValue == "gemini")
        #expect(SRTGenerationEngine.localPipeline.rawValue == "localPipeline")
        #expect(LocalPipelineSettings.productionDefault.baseModel == .kotobaWhisperV2)
        #expect(LocalBaseModel.kotobaWhisperV22.rawValue == "kotobaWhisperV22")
        #expect(LocalPipelineSettings.productionDefault.initialPrompt.isEmpty)
        #expect(LocalPipelinePhase.preparing.rawValue == "preparing")
        #expect(LocalPipelineProgress(
            phase: .validating,
            message: "ok",
            currentChunk: 0,
            totalChunks: 0,
            displayPercent: 0
        ).phase == .validating)
        #expect(LocalPipelineError.invalidConfiguration("x").errorDescription != nil)
    }
}
