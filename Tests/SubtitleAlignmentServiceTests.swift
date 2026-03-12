@testable import SubtitleStudioPlus
import Testing

struct SubtitleAlignmentServiceTests {
    @Test
    func parserAcceptsLooseArrowFormat() {
        let srt = """
        1
        00:00:01.000 -> 00:00:02.500
        text
        """
        let parsed = SRTCodec.parseSRT(srt)
        #expect(parsed.count == 1)
        #expect(abs(parsed[0].startTime - 1.0) < 0.001)
    }

    @Test
    func appDialogStateIsEquatable() {
        let a = AppDialogState(title: "t", message: "m", kind: .error)
        let b = AppDialogState(title: "t", message: "m", kind: .error)
        #expect(a != b)
    }
}
