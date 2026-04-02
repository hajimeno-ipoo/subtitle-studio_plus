@testable import SubtitleStudioPlus
import Foundation
import Testing

struct SubtitleAlignmentServiceTests {
    @Test
    func globalOffsetCorrectionImprovesConsistentShift() async {
        let service = makeService()
        let samples = makeSamples(
            duration: 6.0,
            activeRanges: [1.0...1.6, 3.0...3.6]
        )
        let subtitles = [
            SubtitleItem(startTime: 1.15, endTime: 2.15, text: "a"),
            SubtitleItem(startTime: 3.15, endTime: 4.15, text: "b")
        ]

        let aligned = await service.align(
            samples: samples,
            sampleRate: Self.sampleRate,
            totalDuration: 6.0,
            subtitles: subtitles
        )

        #expect(abs(aligned[0].startTime - 0.85) < 0.08)
        #expect(abs(aligned[0].endTime - 1.85) < 0.08)
        #expect(abs(aligned[1].startTime - 2.85) < 0.08)
        #expect(abs(aligned[1].endTime - 3.85) < 0.08)
    }

    @Test
    func alreadyAlignedSubtitleRemainsStable() async {
        let service = makeService()
        let samples = makeSamples(
            duration: 4.0,
            activeRanges: [1.0...1.6]
        )
        let subtitles = [
            SubtitleItem(startTime: 0.85, endTime: 1.85, text: "steady")
        ]

        let aligned = await service.align(
            samples: samples,
            sampleRate: Self.sampleRate,
            totalDuration: 4.0,
            subtitles: subtitles
        )

        #expect(abs(aligned[0].startTime - subtitles[0].startTime) < 0.05)
        #expect(abs(aligned[0].endTime - subtitles[0].endTime) < 0.05)
    }

    @Test
    func endEdgeRefinementTrimsLateSubtitleWithoutBreakingStart() async {
        let service = makeService()
        let samples = makeSamples(
            duration: 4.0,
            activeRanges: [1.0...1.6]
        )
        let subtitles = [
            SubtitleItem(startTime: 0.85, endTime: 2.15, text: "late end")
        ]

        let aligned = await service.align(
            samples: samples,
            sampleRate: Self.sampleRate,
            totalDuration: 4.0,
            subtitles: subtitles
        )

        #expect(abs(aligned[0].startTime - 0.85) < 0.08)
        #expect(abs(aligned[0].endTime - 1.85) < 0.08)
    }

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

    private static let sampleRate: Double = 100

    private func makeService() -> SubtitleAlignmentService {
        SubtitleAlignmentService(
            config: AlignmentConfig(
                searchWindowPad: 0.8,
                rmsWindowSize: 0.05,
                thresholdRatio: 0.25,
                minVolumeAbsolute: 0.05,
                padStart: 0.15,
                padEnd: 0.25,
                maxSnapDistance: 0.5,
                minGapFill: 0.05,
                useAdaptiveThreshold: false
            )
        )
    }

    private func makeSamples(
        duration: TimeInterval,
        activeRanges: [ClosedRange<TimeInterval>]
    ) -> [Float] {
        let frameCount = Int(duration * Self.sampleRate)
        return (0..<frameCount).map { frame in
            let time = Double(frame) / Self.sampleRate
            return activeRanges.contains(where: { $0.contains(time) }) ? 1.0 : 0.0
        }
    }
}
