import Observation
import Foundation

@MainActor
@Observable
final class SettingsStore {
    private let loadKeychain: @Sendable () -> String
    private let saveKeychain: @Sendable (String) -> Void
    var geminiAPIKey = ""
    var isLoadingAPIKey = false
    var isSavingAPIKey = false
    private var hasLoadedAPIKey = false

    // Auto-Align settings
    var autoAlignRMSWindowSize: Double = 0.005 // 5ms for higher precision
    var autoAlignThresholdRatio: Float = 0.12
    var autoAlignMinGapFill: Double = 0.3
    var autoAlignUseAdaptiveThreshold: Bool = true // New: adaptive threshold

    init(
        loadKeychain: @escaping @Sendable () -> String = { KeychainStore().load() },
        saveKeychain: @escaping @Sendable (String) -> Void = { KeychainStore().save($0) }
    ) {
        self.loadKeychain = loadKeychain
        self.saveKeychain = saveKeychain
    }

    func loadIfNeeded() async {
        guard !hasLoadedAPIKey, !isLoadingAPIKey else { return }
        isLoadingAPIKey = true
        defer { isLoadingAPIKey = false }

        let loadedKey = await Task.detached(priority: .userInitiated) { [loadKeychain] in
            loadKeychain()
        }.value

        geminiAPIKey = loadedKey
        hasLoadedAPIKey = true

        // Load auto-align settings from UserDefaults
        let defaults = UserDefaults.standard
        autoAlignRMSWindowSize = defaults.double(forKey: "autoAlignRMSWindowSize")
        if autoAlignRMSWindowSize == 0 { autoAlignRMSWindowSize = 0.005 } // default
        autoAlignThresholdRatio = defaults.float(forKey: "autoAlignThresholdRatio")
        if autoAlignThresholdRatio == 0 { autoAlignThresholdRatio = 0.12 }
        autoAlignMinGapFill = defaults.double(forKey: "autoAlignMinGapFill")
        if autoAlignMinGapFill == 0 { autoAlignMinGapFill = 0.3 }
        autoAlignUseAdaptiveThreshold = defaults.bool(forKey: "autoAlignUseAdaptiveThreshold")
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

        // Persist auto-align settings to UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(autoAlignRMSWindowSize, forKey: "autoAlignRMSWindowSize")
        defaults.set(autoAlignThresholdRatio, forKey: "autoAlignThresholdRatio")
        defaults.set(autoAlignMinGapFill, forKey: "autoAlignMinGapFill")
        defaults.set(autoAlignUseAdaptiveThreshold, forKey: "autoAlignUseAdaptiveThreshold")
    }
}
