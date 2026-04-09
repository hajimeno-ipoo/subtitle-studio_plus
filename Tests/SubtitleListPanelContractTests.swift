import Testing

struct SubtitleListPanelContractTests {
    @Test
    func autoScrollTracksHighlightedSubtitleInsteadOfPlaybackTicks() throws {
        let source = try loadProjectFile("Sources/Views/SubtitleListPanel.swift")

        try requireContains(source, token: ".onChange(of: viewModel.highlightedSubtitleID)", file: "Sources/Views/SubtitleListPanel.swift")
        try requireContains(source, token: "proxy.scrollTo(activeID, anchor: .center)", file: "Sources/Views/SubtitleListPanel.swift")
        if source.contains(".onChange(of: viewModel.currentTime)") {
            Issue.record("Subtitle list should no longer auto-scroll on every playback tick")
        }
    }
}
