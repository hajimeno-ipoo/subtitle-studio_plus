import Observation
import Foundation

@MainActor
@Observable
final class SettingsStore {
    private enum DefaultsKey {
        static let selectedSRTGenerationEngine = "selectedSRTGenerationEngine"
        static let localPipelineSettings = "localPipelineSettings"
        static let localPipelineBaseModelWasCustomized = "localPipelineBaseModelWasCustomized"
        static let autoAlignRMSWindowSize = "autoAlignRMSWindowSize"
        static let autoAlignThresholdRatio = "autoAlignThresholdRatio"
        static let autoAlignMinGapFill = "autoAlignMinGapFill"
        static let autoAlignUseAdaptiveThreshold = "autoAlignUseAdaptiveThreshold"
    }

    private let loadKeychain: @Sendable () -> String
    private let saveKeychain: @Sendable (String) -> Void
    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var geminiAPIKey = ""
    var isLoadingAPIKey = false
    var isSavingAPIKey = false
    private var hasLoadedAPIKey = false
    private var hasLoadedNonSecretSettings = false
    private var localPipelineBaseModelWasCustomized = false

    var selectedSRTGenerationEngine: SRTGenerationEngine = .gemini {
        didSet { persistNonSecretSettings() }
    }
    var localPipelineSettings: LocalPipelineSettings = .productionDefault {
        didSet { persistNonSecretSettings() }
    }

    // Auto-Align settings
    var autoAlignRMSWindowSize: Double = 0.005 { didSet { persistNonSecretSettings() } } // 5ms for higher precision
    var autoAlignThresholdRatio: Float = 0.12 { didSet { persistNonSecretSettings() } }
    var autoAlignMinGapFill: Double = 0.3 { didSet { persistNonSecretSettings() } }
    var autoAlignUseAdaptiveThreshold: Bool = true { didSet { persistNonSecretSettings() } } // New: adaptive threshold

    init(
        loadKeychain: @escaping @Sendable () -> String = { KeychainStore().load() },
        saveKeychain: @escaping @Sendable (String) -> Void = { KeychainStore().save($0) },
        userDefaults: UserDefaults = .standard
    ) {
        self.loadKeychain = loadKeychain
        self.saveKeychain = saveKeychain
        self.userDefaults = userDefaults
    }

    func loadIfNeeded() async {
        if !hasLoadedNonSecretSettings {
            loadNonSecretSettings()
            hasLoadedNonSecretSettings = true
        }

        guard !hasLoadedAPIKey, !isLoadingAPIKey else { return }
        isLoadingAPIKey = true
        defer { isLoadingAPIKey = false }

        let loadedKey = await Task.detached(priority: .userInitiated) { [loadKeychain] in
            loadKeychain()
        }.value

        geminiAPIKey = loadedKey
        hasLoadedAPIKey = true
    }

    func persist(_ value: String? = nil) async {
        guard !isSavingAPIKey else { return }
        isSavingAPIKey = true
        defer { isSavingAPIKey = false }

        let trimmed = (value ?? geminiAPIKey).trimmingCharacters(in: .whitespacesAndNewlines)
        await Task.detached(priority: .userInitiated) { [saveKeychain] in
            saveKeychain(trimmed)
        }.value

        geminiAPIKey = trimmed
        hasLoadedAPIKey = true
    }

    func markLocalPipelineBaseModelCustomized() {
        guard !localPipelineBaseModelWasCustomized else { return }
        localPipelineBaseModelWasCustomized = true
        persistNonSecretSettings()
    }

    func applyRecommendedLocalBaseModelIfNeeded(for fileName: String) {
        guard !localPipelineBaseModelWasCustomized else { return }
        localPipelineSettings.baseModel = recommendedLocalBaseModel(for: fileName)
    }

    private func loadNonSecretSettings() {
        if let rawEngine = userDefaults.string(forKey: DefaultsKey.selectedSRTGenerationEngine),
           let loadedEngine = SRTGenerationEngine(rawValue: rawEngine) {
            selectedSRTGenerationEngine = loadedEngine
        } else {
            selectedSRTGenerationEngine = .gemini
        }

        if let encodedLocalSettings = userDefaults.data(forKey: DefaultsKey.localPipelineSettings),
           let decodedLocalSettings = try? decoder.decode(LocalPipelineSettings.self, from: encodedLocalSettings) {
            localPipelineSettings = normalizeLocalPipelineSettings(decodedLocalSettings)
        } else {
            localPipelineSettings = .productionDefault
        }

        if userDefaults.object(forKey: DefaultsKey.localPipelineBaseModelWasCustomized) != nil {
            localPipelineBaseModelWasCustomized = userDefaults.bool(forKey: DefaultsKey.localPipelineBaseModelWasCustomized)
        } else {
            localPipelineBaseModelWasCustomized = localPipelineSettings.baseModel != LocalPipelineSettings.productionDefault.baseModel
        }

        if userDefaults.object(forKey: DefaultsKey.autoAlignRMSWindowSize) != nil {
            autoAlignRMSWindowSize = userDefaults.double(forKey: DefaultsKey.autoAlignRMSWindowSize)
        } else {
            autoAlignRMSWindowSize = 0.005
        }

        if userDefaults.object(forKey: DefaultsKey.autoAlignThresholdRatio) != nil {
            autoAlignThresholdRatio = userDefaults.float(forKey: DefaultsKey.autoAlignThresholdRatio)
        } else {
            autoAlignThresholdRatio = 0.12
        }

        if userDefaults.object(forKey: DefaultsKey.autoAlignMinGapFill) != nil {
            autoAlignMinGapFill = userDefaults.double(forKey: DefaultsKey.autoAlignMinGapFill)
        } else {
            autoAlignMinGapFill = 0.3
        }

        if userDefaults.object(forKey: DefaultsKey.autoAlignUseAdaptiveThreshold) != nil {
            autoAlignUseAdaptiveThreshold = userDefaults.bool(forKey: DefaultsKey.autoAlignUseAdaptiveThreshold)
        } else {
            autoAlignUseAdaptiveThreshold = true
        }
    }

    private func persistNonSecretSettings() {
        guard hasLoadedNonSecretSettings else { return }
        userDefaults.set(selectedSRTGenerationEngine.rawValue, forKey: DefaultsKey.selectedSRTGenerationEngine)
        if let encodedLocalSettings = try? encoder.encode(localPipelineSettings) {
            userDefaults.set(encodedLocalSettings, forKey: DefaultsKey.localPipelineSettings)
        }
        userDefaults.set(localPipelineBaseModelWasCustomized, forKey: DefaultsKey.localPipelineBaseModelWasCustomized)

        userDefaults.set(autoAlignRMSWindowSize, forKey: DefaultsKey.autoAlignRMSWindowSize)
        userDefaults.set(autoAlignThresholdRatio, forKey: DefaultsKey.autoAlignThresholdRatio)
        userDefaults.set(autoAlignMinGapFill, forKey: DefaultsKey.autoAlignMinGapFill)
        userDefaults.set(autoAlignUseAdaptiveThreshold, forKey: DefaultsKey.autoAlignUseAdaptiveThreshold)
    }

    private func recommendedLocalBaseModel(for fileName: String) -> LocalBaseModel {
        let scalars = fileName.unicodeScalars
        let hasJapanese = scalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        let hasLatin = scalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }

        if hasLatin && !hasJapanese {
            return .kotobaWhisperBilingual
        }
        if hasJapanese && hasLatin {
            return .kotobaWhisperBilingual
        }
        return .kotobaWhisperV2
    }

    private func normalizeLocalPipelineSettings(_ settings: LocalPipelineSettings) -> LocalPipelineSettings {
        var normalized = settings

        if normalized.aeneasPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.aeneasPythonPath = LocalPipelineSettings.productionDefault.aeneasPythonPath
        }
        if normalized.aeneasScriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.aeneasScriptPath = LocalPipelineSettings.productionDefault.aeneasScriptPath
        }
        if normalized.correctionDictionaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.correctionDictionaryPath = LocalPipelineSettings.productionDefault.correctionDictionaryPath
        }
        if normalized.knownLyricsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.knownLyricsPath = LocalPipelineSettings.productionDefault.knownLyricsPath
        }
        if normalized.outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.outputDirectoryPath = LocalPipelineSettings.productionDefault.outputDirectoryPath
        }

        return normalized
    }
}
