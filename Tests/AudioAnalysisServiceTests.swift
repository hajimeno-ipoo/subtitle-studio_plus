@testable import SubtitleStudioPlus
import Testing

struct AudioAnalysisServiceTests {
    @Test
    func parseSSEPayloadExtractsTextAndFinishReason() throws {
        let payload = """
        {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"1\\n00:00:00,000 --> 00:00:01,000\\nHello"}]}}]}
        """

        let event = try AudioAnalysisService.parseSSEPayload(payload)

        #expect(event.text.contains("Hello"))
        #expect(event.finishReason == "STOP")
        #expect(event.blockReason == nil)
    }

    @Test
    func parseSSEPayloadExtractsBlockReason() throws {
        let payload = """
        {"promptFeedback":{"blockReason":"SAFETY"}}
        """

        let event = try AudioAnalysisService.parseSSEPayload(payload)

        #expect(event.blockReason == "SAFETY")
        #expect(event.text.isEmpty)
    }

    @Test
    func mergeStreamTextHandlesSnapshotsAndDeltas() {
        #expect(AudioAnalysisService.mergeStreamText(existing: "", incoming: "abc") == "abc")
        #expect(AudioAnalysisService.mergeStreamText(existing: "abc", incoming: "abcdef") == "abcdef")
        #expect(AudioAnalysisService.mergeStreamText(existing: "abc", incoming: "def") == "abcdef")
        #expect(AudioAnalysisService.mergeStreamText(existing: "abcdef", incoming: "def") == "abcdef")
    }
}
