import Observation

@MainActor
@Observable
final class SettingsStore {
    private let loadKeychain: @Sendable () -> String
    private let saveKeychain: @Sendable (String) -> Void
    var geminiAPIKey = ""
    var isLoadingAPIKey = false
    var isSavingAPIKey = false
    private var hasLoadedAPIKey = false

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
}
