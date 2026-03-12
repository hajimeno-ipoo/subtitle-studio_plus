import Observation

@Observable
final class SettingsStore {
    private let keychain = KeychainStore()
    var geminiAPIKey: String

    init() {
        geminiAPIKey = keychain.load()
    }

    func persist() {
        keychain.save(geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
