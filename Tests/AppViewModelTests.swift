@testable import SubtitleStudioPlus
import Foundation
import Testing

@MainActor
struct AppViewModelTests {
    @Test
    func timelineFrameEditCanBeUndone() {
        let subtitleID = UUID()
        let viewModel = AppViewModel()
        viewModel.subtitles = [
            SubtitleItem(id: subtitleID, startTime: 1.0, endTime: 2.0, text: "hello")
        ]

        viewModel.updateSubtitleFrame(id: subtitleID, startTime: 1.4, endTime: 2.6)

        #expect(viewModel.canUndo)
        #expect(viewModel.subtitles[0].startTime == 1.4)
        #expect(viewModel.subtitles[0].endTime == 2.6)

        viewModel.undo()

        #expect(viewModel.subtitles[0].startTime == 1.0)
        #expect(viewModel.subtitles[0].endTime == 2.0)
    }
}
