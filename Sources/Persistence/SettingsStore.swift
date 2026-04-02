import Observation
import Foundation

@MainActor
@Observable
final class SettingsStore {
    private enum DefaultsKey {
        static let selectedSRTGenerationEngine = "selectedSRTGenerationEngine"
        static let localPipelineSettings = "localPipelineSettings"
        static let localSRTPreset = "localSRTPreset"
        static let localPipelineBaseModelWasCustomized = "localPipelineBaseModelWasCustomized"
        static let autoAlignRMSWindowSize = "autoAlignRMSWindowSize"
        static let autoAlignThresholdRatio = "autoAlignThresholdRatio"
        static let autoAlignMinGapFill = "autoAlignMinGapFill"
        static let autoAlignUseAdaptiveThreshold = "autoAlignUseAdaptiveThreshold"
        static let utoAlignPreset = "utoAlignPreset"
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
    private var isApplyingLocalSRTPreset = false
    private var isApplyingUTOAlignPreset = false

    var selectedSRTGenerationEngine: SRTGenerationEngine = .gemini {
        didSet { persistNonSecretSettings() }
    }
    var localSRTPreset: LocalSRTPreset = .recommended {
        didSet { persistNonSecretSettings() }
    }
    var localPipelineSettings: LocalPipelineSettings = .productionDefault {
        didSet {
            syncLocalSRTPresetFromCurrentSettings()
            persistNonSecretSettings()
        }
    }

    // Auto-Align settings
    var utoAlignPreset: UTOAlignPreset = .recommended {
        didSet { persistNonSecretSettings() }
    }
    var autoAlignRMSWindowSize: Double = 0.005 {
        didSet {
            syncUTOAlignPresetFromCurrentSettings()
            persistNonSecretSettings()
        }
    } // 5ms for higher precision
    var autoAlignThresholdRatio: Float = 0.12 {
        didSet {
            syncUTOAlignPresetFromCurrentSettings()
            persistNonSecretSettings()
        }
    }
    var autoAlignMinGapFill: Double = 0.3 {
        didSet {
            syncUTOAlignPresetFromCurrentSettings()
            persistNonSecretSettings()
        }
    }
    var autoAlignUseAdaptiveThreshold: Bool = true {
        didSet {
            syncUTOAlignPresetFromCurrentSettings()
            persistNonSecretSettings()
        }
    } // New: adaptive threshold

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

    func applyLocalSRTPreset(_ preset: LocalSRTPreset) {
        guard preset != .custom else {
            localSRTPreset = deriveLocalSRTPreset(from: localPipelineSettings)
            return
        }

        let tunedValues = localSRTPresetValues(for: preset)
        isApplyingLocalSRTPreset = true

        var updated = localPipelineSettings
        updated.chunkLengthSeconds = tunedValues.chunkLengthSeconds
        updated.overlapSeconds = tunedValues.overlapSeconds
        updated.temperature = tunedValues.temperature
        updated.beamSize = tunedValues.beamSize
        updated.noSpeechThreshold = tunedValues.noSpeechThreshold
        updated.logprobThreshold = tunedValues.logprobThreshold
        localPipelineSettings = updated
        localSRTPreset = preset

        isApplyingLocalSRTPreset = false
    }

    func applyUTOAlignPreset(_ preset: UTOAlignPreset) {
        guard preset != .custom else {
            utoAlignPreset = deriveUTOAlignPreset(
                rmsWindowSize: autoAlignRMSWindowSize,
                thresholdRatio: autoAlignThresholdRatio,
                minGapFill: autoAlignMinGapFill,
                useAdaptiveThreshold: autoAlignUseAdaptiveThreshold
            )
            return
        }

        let tunedValues = utoAlignPresetValues(for: preset)
        isApplyingUTOAlignPreset = true

        autoAlignRMSWindowSize = tunedValues.rmsWindowSize
        autoAlignThresholdRatio = tunedValues.thresholdRatio
        autoAlignMinGapFill = tunedValues.minGapFill
        autoAlignUseAdaptiveThreshold = tunedValues.useAdaptiveThreshold
        utoAlignPreset = preset

        isApplyingUTOAlignPreset = false
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

        if let rawLocalPreset = userDefaults.string(forKey: DefaultsKey.localSRTPreset),
           let loadedLocalPreset = LocalSRTPreset(rawValue: rawLocalPreset) {
            localSRTPreset = loadedLocalPreset
        } else {
            localSRTPreset = deriveLocalSRTPreset(from: localPipelineSettings)
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

        if let rawUTOAlignPreset = userDefaults.string(forKey: DefaultsKey.utoAlignPreset),
           let loadedUTOAlignPreset = UTOAlignPreset(rawValue: rawUTOAlignPreset) {
            utoAlignPreset = loadedUTOAlignPreset
        } else {
            utoAlignPreset = deriveUTOAlignPreset(
                rmsWindowSize: autoAlignRMSWindowSize,
                thresholdRatio: autoAlignThresholdRatio,
                minGapFill: autoAlignMinGapFill,
                useAdaptiveThreshold: autoAlignUseAdaptiveThreshold
            )
        }
    }

    private func persistNonSecretSettings() {
        guard hasLoadedNonSecretSettings else { return }
        userDefaults.set(selectedSRTGenerationEngine.rawValue, forKey: DefaultsKey.selectedSRTGenerationEngine)
        if let encodedLocalSettings = try? encoder.encode(localPipelineSettings) {
            userDefaults.set(encodedLocalSettings, forKey: DefaultsKey.localPipelineSettings)
        }
        userDefaults.set(localSRTPreset.rawValue, forKey: DefaultsKey.localSRTPreset)
        userDefaults.set(localPipelineBaseModelWasCustomized, forKey: DefaultsKey.localPipelineBaseModelWasCustomized)

        userDefaults.set(autoAlignRMSWindowSize, forKey: DefaultsKey.autoAlignRMSWindowSize)
        userDefaults.set(autoAlignThresholdRatio, forKey: DefaultsKey.autoAlignThresholdRatio)
        userDefaults.set(autoAlignMinGapFill, forKey: DefaultsKey.autoAlignMinGapFill)
        userDefaults.set(autoAlignUseAdaptiveThreshold, forKey: DefaultsKey.autoAlignUseAdaptiveThreshold)
        userDefaults.set(utoAlignPreset.rawValue, forKey: DefaultsKey.utoAlignPreset)
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

        if normalized.baseModel == .kotobaWhisperBilingual {
            // keep bilingual as-is
        } else {
            normalized.baseModel = .kotobaWhisperV2
        }

        if normalized.aeneasPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.aeneasPythonPath = LocalPipelineSettings.productionDefault.aeneasPythonPath
        }
        if normalized.aeneasScriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.aeneasScriptPath = LocalPipelineSettings.productionDefault.aeneasScriptPath
        }
        if normalized.correctionDictionaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.correctionDictionaryPath = LocalPipelineSettings.productionDefault.correctionDictionaryPath
        }
        if normalized.outputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.outputDirectoryPath = LocalPipelineSettings.productionDefault.outputDirectoryPath
        }

        return normalized
    }

    private func syncLocalSRTPresetFromCurrentSettings() {
        guard !isApplyingLocalSRTPreset else { return }
        let derived = deriveLocalSRTPreset(from: localPipelineSettings)
        guard localSRTPreset != derived else { return }
        localSRTPreset = derived
    }

    private func syncUTOAlignPresetFromCurrentSettings() {
        guard !isApplyingUTOAlignPreset else { return }
        let derived = deriveUTOAlignPreset(
            rmsWindowSize: autoAlignRMSWindowSize,
            thresholdRatio: autoAlignThresholdRatio,
            minGapFill: autoAlignMinGapFill,
            useAdaptiveThreshold: autoAlignUseAdaptiveThreshold
        )
        guard utoAlignPreset != derived else { return }
        utoAlignPreset = derived
    }

    private func deriveLocalSRTPreset(from settings: LocalPipelineSettings) -> LocalSRTPreset {
        if matches(settings, preset: .recommended) {
            return .recommended
        }
        if matches(settings, preset: .highAccuracy) {
            return .highAccuracy
        }
        if matches(settings, preset: .fast) {
            return .fast
        }
        return .custom
    }

    private func deriveUTOAlignPreset(
        rmsWindowSize: Double,
        thresholdRatio: Float,
        minGapFill: Double,
        useAdaptiveThreshold: Bool
    ) -> UTOAlignPreset {
        if matchesUTOAlignPreset(
            preset: .recommended,
            rmsWindowSize: rmsWindowSize,
            thresholdRatio: thresholdRatio,
            minGapFill: minGapFill,
            useAdaptiveThreshold: useAdaptiveThreshold
        ) {
            return .recommended
        }
        if matchesUTOAlignPreset(
            preset: .sensitive,
            rmsWindowSize: rmsWindowSize,
            thresholdRatio: thresholdRatio,
            minGapFill: minGapFill,
            useAdaptiveThreshold: useAdaptiveThreshold
        ) {
            return .sensitive
        }
        if matchesUTOAlignPreset(
            preset: .strict,
            rmsWindowSize: rmsWindowSize,
            thresholdRatio: thresholdRatio,
            minGapFill: minGapFill,
            useAdaptiveThreshold: useAdaptiveThreshold
        ) {
            return .strict
        }
        return .custom
    }

    private func matches(_ settings: LocalPipelineSettings, preset: LocalSRTPreset) -> Bool {
        let tunedValues = localSRTPresetValues(for: preset)
        return settings.chunkLengthSeconds == tunedValues.chunkLengthSeconds
            && settings.overlapSeconds == tunedValues.overlapSeconds
            && settings.temperature == tunedValues.temperature
            && settings.beamSize == tunedValues.beamSize
            && settings.noSpeechThreshold == tunedValues.noSpeechThreshold
            && settings.logprobThreshold == tunedValues.logprobThreshold
    }

    private func matchesUTOAlignPreset(
        preset: UTOAlignPreset,
        rmsWindowSize: Double,
        thresholdRatio: Float,
        minGapFill: Double,
        useAdaptiveThreshold: Bool
    ) -> Bool {
        let tunedValues = utoAlignPresetValues(for: preset)
        return rmsWindowSize == tunedValues.rmsWindowSize
            && thresholdRatio == tunedValues.thresholdRatio
            && minGapFill == tunedValues.minGapFill
            && useAdaptiveThreshold == tunedValues.useAdaptiveThreshold
    }

    private func localSRTPresetValues(
        for preset: LocalSRTPreset
    ) -> (
        chunkLengthSeconds: Double,
        overlapSeconds: Double,
        temperature: Double,
        beamSize: Int,
        noSpeechThreshold: Double,
        logprobThreshold: Double
    ) {
        switch preset {
        case .recommended, .custom:
            return (8.0, 1.0, 0.0, 5, 0.6, -1.0)
        case .highAccuracy:
            return (6.0, 1.2, 0.0, 7, 0.5, -1.0)
        case .fast:
            return (10.0, 0.8, 0.0, 3, 0.7, -0.8)
        }
    }

    private func utoAlignPresetValues(
        for preset: UTOAlignPreset
    ) -> (
        rmsWindowSize: Double,
        thresholdRatio: Float,
        minGapFill: Double,
        useAdaptiveThreshold: Bool
    ) {
        switch preset {
        case .recommended, .custom:
            return (0.005, 0.12, 0.3, true)
        case .sensitive:
            return (0.004, 0.09, 0.35, true)
        case .strict:
            return (0.007, 0.16, 0.2, false)
        }
    }
}
