import Testing

struct MainWindowBehaviorContractTests {
    @Test
    func resolveBannerUpdatesMinimumSizeWithoutRecenteringWindow() throws {
        let rootViewSource = try loadProjectFile("Sources/Views/RootView.swift")
        try requireContains(rootViewSource, token: "AppDelegate.shared?.updateMainWindowMinimumSize(resolveSessionActive: viewModel.isResolveSessionActive)", file: "Sources/Views/RootView.swift")
        if rootViewSource.contains("AppDelegate.shared?.adjustMainWindowFrame(resolveSessionActive: viewModel.isResolveSessionActive)") {
            Issue.record("Resolve session changes should not recenter the main window")
        }

        let appDelegateSource = try loadProjectFile("Sources/App/AppDelegate.swift")
        try requireContains(appDelegateSource, token: "adjustMainWindowFrame(resolveSessionActive: false, recenter: true)", file: "Sources/App/AppDelegate.swift")
        try requireContains(appDelegateSource, token: "func updateMainWindowMinimumSize(resolveSessionActive: Bool)", file: "Sources/App/AppDelegate.swift")
        try requireContains(appDelegateSource, token: "guard recenter else { return }", file: "Sources/App/AppDelegate.swift")
    }
}
