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

@MainActor
struct SettingsStoreTests {
    @Test
    func loadIfNeededRunsOffMainAndOnlyOnce() async {
        let counter = CounterBox()
        let store = SettingsStore(
            loadKeychain: {
                counter.recordLoad()
                Thread.sleep(forTimeInterval: 0.05)
                return "abc123"
            },
            saveKeychain: { _ in }
        )

        let task = Task { await store.loadIfNeeded() }
        await Task.yield()
        #expect(store.isLoadingAPIKey)

        await task.value
        #expect(store.geminiAPIKey == "abc123")
        #expect(store.isLoadingAPIKey == false)
        #expect(counter.loadCount == 1)

        await store.loadIfNeeded()
        #expect(counter.loadCount == 1)
    }

    @Test
    func persistTrimsValueAndResetsBusyFlag() async {
        let counter = CounterBox()
        let store = SettingsStore(
            loadKeychain: { "" },
            saveKeychain: {
                counter.recordSave($0)
                Thread.sleep(forTimeInterval: 0.05)
            }
        )

        let task = Task { await store.persist("  my-key  ") }
        await Task.yield()
        #expect(store.isSavingAPIKey)

        await task.value
        #expect(store.isSavingAPIKey == false)
        #expect(store.geminiAPIKey == "my-key")
        #expect(counter.savedValues == ["my-key"])
    }
}
