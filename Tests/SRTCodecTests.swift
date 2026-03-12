@testable import SubtitleStudioPlus
import Testing

struct SRTCodecTests {
    @Test
    func formatAndParseTime() {
        #expect(SRTCodec.formatSRTTime(65.432) == "00:01:05,432")
        #expect(abs(SRTCodec.parseTime("00:01:05,432") - 65.432) < 0.001)
        #expect(abs(SRTCodec.parseTime("01:05.500") - 65.5) < 0.001)
    }

    @Test
    func generateAndParseRoundTrip() {
        let items = [
            SubtitleItem(startTime: 0.2, endTime: 1.8, text: "hello"),
            SubtitleItem(startTime: 2.1, endTime: 3.4, text: "line 1\nline 2"),
        ]
        let srt = SRTCodec.generateSRT(from: items)
        let parsed = SRTCodec.parseSRT(srt)
        #expect(parsed.count == 2)
        #expect(parsed[1].text == "line 1\nline 2")
    }
}
