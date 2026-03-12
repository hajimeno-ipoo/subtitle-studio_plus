import Observation

@Observable
final class SettingsStore {
    private let keychain = KeychainStore()
    var geminiAPIKey = ""
    private var hasLoadedAPIKey = false

    func loadIfNeeded() {
        guard !hasLoadedAPIKey else { return }
        geminiAPIKey = keychain.load()
        hasLoadedAPIKey = true
    }

    func persist() {
        geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.save(geminiAPIKey)
        hasLoadedAPIKey = true
    }
}
