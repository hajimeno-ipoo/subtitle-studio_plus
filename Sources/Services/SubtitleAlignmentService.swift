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
    private struct AlignmentEdge {
        let time: TimeInterval
        let strength: Float
    }

    private struct AlignmentEvidence {
        let subtitle: SubtitleItem
        let totalDuration: TimeInterval
        let searchStart: TimeInterval
        let searchEnd: TimeInterval
        let rmsProfile: [Float]
        let isSpeech: [Bool]
        let risingEdges: [AlignmentEdge]
        let fallingEdges: [AlignmentEdge]
    }

    private let config: AlignmentConfig
    private let waveformService = WaveformService()
    private let minimumDuration: TimeInterval = 0.2
    private let transitionWindow: TimeInterval = 0.12

    init(config: AlignmentConfig) {
        self.config = config
    }

    func align(
        audioURL: URL,
        subtitles: [SubtitleItem],
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> [SubtitleItem] {
        await progress("Decoding audio data...")
        let decoded = try waveformService.decodedMonoSamples(url: audioURL)

        return await align(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            totalDuration: decoded.duration,
            subtitles: subtitles,
            progress: progress
        )
    }

    func align(
        samples: [Float],
        sampleRate: Double,
        totalDuration: TimeInterval,
        subtitles: [SubtitleItem],
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> [SubtitleItem] {
        await progress("Analyzing subtitle edges...")

        var evidences: [AlignmentEvidence] = []
        evidences.reserveCapacity(subtitles.count)

        for index in subtitles.indices {
            if index % 20 == 0 {
                await progress("Aligning... \(Int((Double(index) / Double(max(subtitles.count, 1))) * 100))%")
                try? await Task.sleep(for: .milliseconds(1))
            }
            evidences.append(
                buildEvidence(
                    for: subtitles[index],
                    audioData: samples,
                    sampleRate: sampleRate,
                    totalDuration: totalDuration
                )
            )
        }

        let globalOffset = estimateGlobalOffset(from: evidences)
        var aligned: [SubtitleItem] = []
        aligned.reserveCapacity(evidences.count)

        for evidence in evidences {
            let best = chooseBestCandidate(
                for: evidence,
                globalOffset: globalOffset,
                previous: aligned.last
            )
            aligned.append(best)
        }

        return resolveOverlaps(in: aligned, totalDuration: totalDuration)
    }

    private func buildEvidence(
        for subtitle: SubtitleItem,
        audioData: [Float],
        sampleRate: Double,
        totalDuration: TimeInterval
    ) -> AlignmentEvidence {
        let searchStart = max(0, subtitle.startTime - config.searchWindowPad)
        let searchEnd = min(totalDuration, subtitle.endTime + config.searchWindowPad)
        let startIndex = max(0, Int(searchStart * sampleRate))
        let endIndex = min(audioData.count, Int(searchEnd * sampleRate))

        guard endIndex > startIndex, startIndex < audioData.count else {
            return AlignmentEvidence(
                subtitle: subtitle,
                totalDuration: totalDuration,
                searchStart: searchStart,
                searchEnd: searchEnd,
                rmsProfile: [],
                isSpeech: [],
                risingEdges: [],
                fallingEdges: []
            )
        }

        let segment = Array(audioData[startIndex..<endIndex])
        let windowSize = max(1, Int(sampleRate * config.rmsWindowSize))
        let rmsProfile = calculateRMS(segment, windowSize: windowSize)
        guard let maxRMS = rmsProfile.max(), maxRMS >= config.minVolumeAbsolute else {
            return AlignmentEvidence(
                subtitle: subtitle,
                totalDuration: totalDuration,
                searchStart: searchStart,
                searchEnd: searchEnd,
                rmsProfile: rmsProfile,
                isSpeech: Array(repeating: false, count: rmsProfile.count),
                risingEdges: [],
                fallingEdges: []
            )
        }

        let threshold: Float
        if config.useAdaptiveThreshold {
            threshold = calculateAdaptiveThreshold(rmsProfile)
        } else {
            threshold = max(maxRMS * config.thresholdRatio, config.minVolumeAbsolute)
        }

        var isSpeech = rmsProfile.map { $0 > threshold }
        fillShortGaps(in: &isSpeech)
        let edges = extractEdges(from: isSpeech, rmsProfile: rmsProfile, searchStart: searchStart)

        return AlignmentEvidence(
            subtitle: subtitle,
            totalDuration: totalDuration,
            searchStart: searchStart,
            searchEnd: searchEnd,
            rmsProfile: rmsProfile,
            isSpeech: isSpeech,
            risingEdges: edges.rising,
            fallingEdges: edges.falling
        )
    }

    private func fillShortGaps(in isSpeech: inout [Bool]) {
        let minGapFrames = max(1, Int(config.minGapFill / max(config.rmsWindowSize, 0.001)))
        var gapStart: Int?

        for index in isSpeech.indices {
            if !isSpeech[index] {
                gapStart = gapStart ?? index
                continue
            }

            if let currentGapStart = gapStart,
               index - currentGapStart <= minGapFrames,
               currentGapStart > 0,
               isSpeech[currentGapStart - 1] {
                for fill in currentGapStart..<index {
                    isSpeech[fill] = true
                }
            }
            gapStart = nil
        }
    }

    private func extractEdges(
        from isSpeech: [Bool],
        rmsProfile: [Float],
        searchStart: TimeInterval
    ) -> (rising: [AlignmentEdge], falling: [AlignmentEdge]) {
        guard !isSpeech.isEmpty else { return ([], []) }

        var rising: [AlignmentEdge] = []
        var falling: [AlignmentEdge] = []

        if isSpeech.first == true {
            rising.append(makeEdge(index: 0, rising: true, rmsProfile: rmsProfile, searchStart: searchStart))
        }

        for index in 1..<isSpeech.count {
            if isSpeech[index] && !isSpeech[index - 1] {
                rising.append(makeEdge(index: index, rising: true, rmsProfile: rmsProfile, searchStart: searchStart))
            }
            if !isSpeech[index] && isSpeech[index - 1] {
                falling.append(makeEdge(index: index, rising: false, rmsProfile: rmsProfile, searchStart: searchStart))
            }
        }

        if isSpeech.last == true {
            falling.append(makeEdge(index: isSpeech.count, rising: false, rmsProfile: rmsProfile, searchStart: searchStart))
        }

        return (rising, falling)
    }

    private func makeEdge(
        index: Int,
        rising: Bool,
        rmsProfile: [Float],
        searchStart: TimeInterval
    ) -> AlignmentEdge {
        let beforeAverage = localAverage(in: rmsProfile, start: index - 2, end: index)
        let afterAverage = localAverage(in: rmsProfile, start: index, end: index + 2)
        let rawStrength = rising ? (afterAverage - beforeAverage) : (beforeAverage - afterAverage)
        let strength = max(rawStrength, 0.0001)
        let time = searchStart + (Double(index) * config.rmsWindowSize)
        return AlignmentEdge(time: time, strength: strength)
    }

    private func chooseBestCandidate(
        for evidence: AlignmentEvidence,
        globalOffset: TimeInterval,
        previous: SubtitleItem?
    ) -> SubtitleItem {
        let original = normalize(evidence.subtitle, totalDuration: evidence.totalDuration)
        let globallyShifted = normalize(shift(original, by: globalOffset), totalDuration: evidence.totalDuration)
        let refined = refineCandidate(globallyShifted, evidence: evidence)

        let candidates = [original, globallyShifted, refined]
        var bestCandidate = original
        var bestScore = score(original, evidence: evidence, previous: previous)

        for candidate in candidates.dropFirst() {
            let candidateScore = score(candidate, evidence: evidence, previous: previous)
            if candidateScore > bestScore {
                bestScore = candidateScore
                bestCandidate = candidate
            }
        }

        return bestCandidate
    }

    private func estimateGlobalOffset(from evidences: [AlignmentEvidence]) -> TimeInterval {
        var offsets: [TimeInterval] = []
        offsets.reserveCapacity(evidences.count)

        for evidence in evidences {
            let original = evidence.subtitle
            let startDelta = bestGlobalEdge(in: evidence.risingEdges, target: original.startTime).map {
                ($0.time - config.padStart) - original.startTime
            }
            let endDelta = bestGlobalEdge(in: evidence.fallingEdges, target: original.endTime).map {
                ($0.time + config.padEnd) - original.endTime
            }

            switch (startDelta, endDelta) {
            case let (start?, end?):
                offsets.append((start + end) / 2)
            case let (start?, nil):
                offsets.append(start)
            case let (nil, end?):
                offsets.append(end)
            default:
                continue
            }
        }

        guard !offsets.isEmpty else { return 0 }
        return median(of: offsets)
    }

    private func refineCandidate(_ candidate: SubtitleItem, evidence: AlignmentEvidence) -> SubtitleItem {
        var refined = candidate

        if let bestStart = bestLocalEdge(in: evidence.risingEdges, target: candidate.startTime) {
            refined.startTime = bestStart.time - config.padStart
        }

        if let bestEnd = bestLocalEdge(in: evidence.fallingEdges, target: candidate.endTime) {
            refined.endTime = bestEnd.time + config.padEnd
        }

        return normalize(refined, totalDuration: evidence.totalDuration)
    }

    private func score(
        _ candidate: SubtitleItem,
        evidence: AlignmentEvidence,
        previous: SubtitleItem?
    ) -> Double {
        guard !evidence.rmsProfile.isEmpty, !evidence.isSpeech.isEmpty else {
            let overlapPenalty = max(0, (previous?.endTime ?? 0) - candidate.startTime) * 10
            return -overlapPenalty
        }

        let insideSpeech = speechRatio(in: candidate.startTime...candidate.endTime, evidence: evidence)
        let preStartSpeech = speechRatio(in: (candidate.startTime - transitionWindow)...candidate.startTime, evidence: evidence)
        let postStartSpeech = speechRatio(in: candidate.startTime...(candidate.startTime + transitionWindow), evidence: evidence)
        let preEndSpeech = speechRatio(in: (candidate.endTime - transitionWindow)...candidate.endTime, evidence: evidence)
        let postEndSpeech = speechRatio(in: candidate.endTime...(candidate.endTime + transitionWindow), evidence: evidence)

        let startDistance = nearestDistance(to: candidate.startTime, edges: evidence.risingEdges, fallback: config.searchWindowPad)
        let endDistance = nearestDistance(to: candidate.endTime, edges: evidence.fallingEdges, fallback: config.searchWindowPad)
        let movePenalty = abs(candidate.startTime - evidence.subtitle.startTime) + abs(candidate.endTime - evidence.subtitle.endTime)
        let overlapPenalty = max(0, (previous?.endTime ?? 0) - candidate.startTime)
        let durationPenalty = candidate.endTime - candidate.startTime < minimumDuration ? 2.5 : 0

        var score = 0.0
        score += insideSpeech * 4.0
        score += (postStartSpeech - preStartSpeech) * 2.5
        score += (preEndSpeech - postEndSpeech) * 2.5
        score -= startDistance * 1.4
        score -= endDistance * 1.4
        score -= movePenalty * 0.35
        score -= overlapPenalty * 8.0
        score -= durationPenalty
        return score
    }

    private func bestGlobalEdge(in edges: [AlignmentEdge], target: TimeInterval) -> AlignmentEdge? {
        edges
            .filter { abs($0.time - target) <= config.searchWindowPad }
            .min { lhs, rhs in
                abs(lhs.time - target) < abs(rhs.time - target)
            }
    }

    private func bestLocalEdge(in edges: [AlignmentEdge], target: TimeInterval) -> AlignmentEdge? {
        edges
            .filter { abs($0.time - target) <= config.maxSnapDistance }
            .max { lhs, rhs in
                edgeScore(lhs, target: target) < edgeScore(rhs, target: target)
            }
    }

    private func edgeScore(_ edge: AlignmentEdge, target: TimeInterval) -> Double {
        let distance = abs(edge.time - target)
        return Double(edge.strength) * 2.5 - distance * 0.9
    }

    private func nearestDistance(
        to target: TimeInterval,
        edges: [AlignmentEdge],
        fallback: TimeInterval
    ) -> Double {
        guard let nearest = edges.min(by: { abs($0.time - target) < abs($1.time - target) }) else {
            return fallback
        }
        return abs(nearest.time - target)
    }

    private func speechRatio(
        in range: ClosedRange<TimeInterval>,
        evidence: AlignmentEvidence
    ) -> Double {
        guard !evidence.isSpeech.isEmpty else { return 0 }

        let clippedLower = max(evidence.searchStart, min(range.lowerBound, evidence.searchEnd))
        let clippedUpper = max(evidence.searchStart, min(range.upperBound, evidence.searchEnd))
        guard clippedUpper > clippedLower else { return 0 }

        let lowerIndex = max(0, Int(floor((clippedLower - evidence.searchStart) / config.rmsWindowSize)))
        let upperIndex = min(evidence.isSpeech.count, Int(ceil((clippedUpper - evidence.searchStart) / config.rmsWindowSize)))
        guard upperIndex > lowerIndex else { return 0 }

        let speechFrames = evidence.isSpeech[lowerIndex..<upperIndex].reduce(0) { $0 + ($1 ? 1 : 0) }
        return Double(speechFrames) / Double(upperIndex - lowerIndex)
    }

    private func resolveOverlaps(in subtitles: [SubtitleItem], totalDuration: TimeInterval) -> [SubtitleItem] {
        guard subtitles.count > 1 else { return subtitles }

        var resolved = subtitles
        for index in 0..<(resolved.count - 1) {
            if resolved[index].endTime > resolved[index + 1].startTime {
                let midpoint = (resolved[index].endTime + resolved[index + 1].startTime) / 2
                let leftEnd = max(resolved[index].startTime + minimumDuration, midpoint)
                let rightStart = min(resolved[index + 1].endTime - minimumDuration, midpoint)

                resolved[index].endTime = min(leftEnd, totalDuration)
                resolved[index + 1].startTime = max(0, rightStart)

                if resolved[index].endTime > resolved[index + 1].startTime {
                    let sharedBoundary = min(
                        max(resolved[index].startTime + minimumDuration, midpoint),
                        resolved[index + 1].endTime - minimumDuration
                    )
                    resolved[index].endTime = sharedBoundary
                    resolved[index + 1].startTime = sharedBoundary
                }
            }
        }

        return resolved
    }

    private func shift(_ subtitle: SubtitleItem, by offset: TimeInterval) -> SubtitleItem {
        SubtitleItem(
            id: subtitle.id,
            startTime: subtitle.startTime + offset,
            endTime: subtitle.endTime + offset,
            text: subtitle.text
        )
    }

    private func normalize(_ subtitle: SubtitleItem, totalDuration: TimeInterval) -> SubtitleItem {
        let maxDuration = max(totalDuration, minimumDuration)
        var start = max(0, min(subtitle.startTime, maxDuration))
        var end = max(start + minimumDuration, subtitle.endTime)

        if end > maxDuration {
            end = maxDuration
            start = max(0, min(start, end - minimumDuration))
        }

        return SubtitleItem(
            id: subtitle.id,
            startTime: start,
            endTime: end,
            text: subtitle.text
        )
    }

    private func calculateAdaptiveThreshold(_ rmsProfile: [Float]) -> Float {
        guard !rmsProfile.isEmpty else { return config.minVolumeAbsolute }

        let sortedRMS = rmsProfile.sorted()
        let noiseFloorIndex = min(sortedRMS.count - 1, Int(Float(sortedRMS.count) * 0.1))
        let speechPeakIndex = min(sortedRMS.count - 1, Int(Float(sortedRMS.count) * 0.9))
        let noiseFloor = sortedRMS[noiseFloorIndex]
        let speechPeak = sortedRMS[speechPeakIndex]
        return max((noiseFloor + speechPeak) / 2, config.minVolumeAbsolute)
    }

    private func localAverage(in values: [Float], start: Int, end: Int) -> Float {
        let lower = max(0, start)
        let upper = min(values.count, end)
        guard upper > lower else { return 0 }
        let slice = values[lower..<upper]
        return slice.reduce(0, +) / Float(slice.count)
    }

    private func median(of values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func calculateRMS(_ samples: [Float], windowSize: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }

        var rmsProfile: [Float] = []
        rmsProfile.reserveCapacity(max(1, samples.count / max(windowSize, 1)))

        for index in stride(from: 0, to: samples.count, by: windowSize) {
            let end = min(index + windowSize, samples.count)
            let window = samples[index..<end]
            let sumSquares = window.reduce(0) { $0 + ($1 * $1) }
            let rms = sqrt(sumSquares / Float(window.count))
            rmsProfile.append(rms)
        }

        return rmsProfile
    }
}
