import Foundation

struct AlignmentConfig {
    let searchWindowPad: Double
    let rmsWindowSize: Double
    let thresholdRatio: Float
    let minVolumeAbsolute: Float
    let padStart: Double
    let padEnd: Double
    let maxSnapDistance: Double
    let minGapFill: Double
    let useAdaptiveThreshold: Bool
}

struct SubtitleAlignmentService {
    private let config: AlignmentConfig
    private let waveformService = WaveformService()

    init(config: AlignmentConfig) {
        self.config = config
    }

    func align(audioURL: URL, subtitles: [SubtitleItem], progress: @escaping @Sendable (String) async -> Void) async throws -> [SubtitleItem] {
        await progress("Decoding audio data...")
        let decoded = try waveformService.decodedMonoSamples(url: audioURL)
        await progress("Analyzing subtitle edges...")

        var aligned: [SubtitleItem] = []
        aligned.reserveCapacity(subtitles.count)

        for index in subtitles.indices {
            if index % 20 == 0 {
                await progress("Aligning... \(Int((Double(index) / Double(max(subtitles.count, 1))) * 100))%")
                try? await Task.sleep(for: .milliseconds(1))
            }
            aligned.append(alignSingleSubtitle(subtitles[index], audioData: decoded.samples, sampleRate: decoded.sampleRate, totalDuration: decoded.duration))
        }

        for index in 0..<max(0, aligned.count - 1) {
            if aligned[index].endTime > aligned[index + 1].startTime {
                let mid = (aligned[index].endTime + aligned[index + 1].startTime) / 2
                aligned[index].endTime = max(aligned[index].startTime, mid - 0.025)
                aligned[index + 1].startTime = min(aligned[index + 1].endTime, mid + 0.025)
            }
        }

        return aligned
    }

    private func alignSingleSubtitle(_ subtitle: SubtitleItem, audioData: [Float], sampleRate: Double, totalDuration: TimeInterval) -> SubtitleItem {
        let searchStart = max(0, subtitle.startTime - config.searchWindowPad)
        let searchEnd = min(totalDuration, subtitle.endTime + config.searchWindowPad)
        let startIndex = Int(searchStart * sampleRate)
        let endIndex = Int(searchEnd * sampleRate)
        guard endIndex > startIndex, startIndex < audioData.count else { return subtitle }

        let segment = Array(audioData[startIndex..<min(endIndex, audioData.count)])
        let windowSize = max(1, Int(sampleRate * config.rmsWindowSize))
        let rmsProfile = calculateRMS(segment, windowSize: windowSize)
        guard let maxRMS = rmsProfile.max(), maxRMS >= config.minVolumeAbsolute else { return subtitle }

        let threshold: Float
        if config.useAdaptiveThreshold {
            threshold = calculateAdaptiveThreshold(rmsProfile, maxRMS)
        } else {
            threshold = max(maxRMS * config.thresholdRatio, config.minVolumeAbsolute)
        }

        var isSpeech = rmsProfile.map { $0 > threshold }

        let minGapFrames = Int(config.minGapFill / config.rmsWindowSize)
        var gapStart: Int?
        for index in isSpeech.indices {
            if !isSpeech[index] {
                gapStart = gapStart ?? index
            } else if let currentGapStart = gapStart, index - currentGapStart <= minGapFrames, currentGapStart > 0, isSpeech[currentGapStart - 1] {
                for fill in currentGapStart..<index {
                    isSpeech[fill] = true
                }
                self.clearGap(&gapStart)
            } else {
                self.clearGap(&gapStart)
            }
        }

        var risingEdges: [Int] = []
        var fallingEdges: [Int] = []
        if isSpeech.first == true {
            risingEdges.append(0)
        }
        for index in 1..<isSpeech.count {
            if isSpeech[index] && !isSpeech[index - 1] {
                risingEdges.append(index)
            }
            if !isSpeech[index] && isSpeech[index - 1] {
                fallingEdges.append(index)
            }
        }
        if isSpeech.last == true {
            fallingEdges.append(isSpeech.count)
        }

        let toTime: (Int) -> TimeInterval = { index in
            searchStart + (Double(index) * config.rmsWindowSize)
        }

        var updated = subtitle
        if let bestStart = nearest(edgeTimes: risingEdges.map(toTime), target: subtitle.startTime, maxDistance: config.maxSnapDistance) {
            updated.startTime = max(0, bestStart - config.padStart)
        }
        if let bestEnd = nearest(edgeTimes: fallingEdges.map(toTime), target: subtitle.endTime, maxDistance: config.maxSnapDistance) {
            updated.endTime = bestEnd + config.padEnd
        }

        if updated.startTime >= updated.endTime {
            updated.endTime = updated.startTime + max(subtitle.endTime - subtitle.startTime, 0.5)
        }
        if updated.endTime - updated.startTime < 0.5, subtitle.endTime - subtitle.startTime > 0.5 {
            updated.endTime = updated.startTime + (subtitle.endTime - subtitle.startTime)
        }
        return updated
    }

    private func calculateAdaptiveThreshold(_ rmsProfile: [Float], _ maxRMS: Float) -> Float {
        // Sort RMS values to find percentiles
        let sortedRMS = rmsProfile.sorted()
        let noiseFloorIndex = Int(Float(sortedRMS.count) * 0.1) // 10th percentile as noise floor
        let noiseFloor = sortedRMS[noiseFloorIndex]
        let speechPeakIndex = Int(Float(sortedRMS.count) * 0.9) // 90th percentile as speech peak
        let speechPeak = sortedRMS[speechPeakIndex]
        
        // Threshold as midpoint between noise floor and speech peak
        let adaptiveThreshold = (noiseFloor + speechPeak) / 2
        return max(adaptiveThreshold, config.minVolumeAbsolute)
    }

    private func nearest(edgeTimes: [TimeInterval], target: TimeInterval, maxDistance: TimeInterval) -> TimeInterval? {
        edgeTimes
            .map { ($0, abs($0 - target)) }
            .filter { $0.1 < maxDistance }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    private func clearGap(_ gapStart: inout Int?) {
        gapStart = nil
    }

    private func calculateRMS(_ samples: [Float], windowSize: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var rmsProfile: [Float] = []
        for i in stride(from: 0, to: samples.count, by: windowSize) {
            let end = min(i + windowSize, samples.count)
            let window = samples[i..<end]
            let sumSquares = window.reduce(0) { $0 + $1 * $1 }
            let rms = sqrt(sumSquares / Float(window.count))
            rmsProfile.append(rms)
        }
        return rmsProfile
    }
}
