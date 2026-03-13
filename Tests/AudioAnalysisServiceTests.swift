@testable import SubtitleStudioPlus
import Testing

struct AudioAnalysisServiceTests {
    @Test
    func cleanGeminiTextRemovesCodeFenceAndWhitespace() {
        let payload = """
        ```srt
        1
        00:00:00,000 --> 00:00:01,000
        Hello
        ```
        """

        let cleaned = AudioAnalysisService.cleanGeminiText(payload)

        #expect(cleaned == "1\n00:00:00,000 --> 00:00:01,000\nHello")
    }

    @Test
    func cleanGeminiTextPreservesPlainSRT() {
        let payload = """
        1
        00:00:00,000 --> 00:00:01,000
        Hello
        """

        let cleaned = AudioAnalysisService.cleanGeminiText(payload)

        #expect(cleaned == payload)
    }
}
