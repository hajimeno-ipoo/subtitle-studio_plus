import Foundation

extension LocalPipelineService {
    func isObviouslyGarbageTranscript(_ text: String, confidence: Double) -> Bool {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else { return true }

        let punctuationSet = CharacterSet(charactersIn: "・、。！？!?…ー-")
        let scalars = normalized.unicodeScalars
        if !scalars.isEmpty && scalars.allSatisfy({ punctuationSet.contains($0) }) {
            return true
        }

        if normalized.allSatisfy({ $0.isNumber }) {
            return true
        }

        if normalized.count == 2 {
            let filtered = normalized.replacingOccurrences(of: " ", with: "")
            if filtered.count == 2, Set(filtered).count == 1 {
                return true
            }
        }

        let latin = normalized.filter { $0.isASCII && $0.isLetter }
        if !latin.isEmpty && latin.count == normalized.count && normalized.count == 1 {
            return true
        }

        if !latin.isEmpty && latin.count == normalized.count && normalized.count <= 2 {
            return true
        }

        if confidence < 0.1 && normalized.count <= 2 {
            return true
        }

        return false
    }

    func buildDraftSegments(
        textSegments: [LocalPipelineBaseSegment],
        timingGuideSegments: [LocalPipelineBaseSegment],
        lyricsReference: LocalLyricsReferenceInput?,
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double,
        logger: RunLogger,
        runId: String
    ) throws -> [LocalPipelineDraftSegment] {
        if let lyricsReference, !lyricsReference.isEmpty {
            let guideSegments = timingGuideSegments.isEmpty ? textSegments : timingGuideSegments
            return try buildDraftSegmentsFromReferenceLyrics(
                lyricsReference,
                guideSegments: guideSegments,
                normalizedAudioURL: normalizedAudioURL,
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate,
                logger: logger,
                runId: runId
            )
        }
        return buildDraftSegmentsFromTranscription(
            textSegments,
            timingGuideSegments: timingGuideSegments,
            totalDuration: Double(normalizedSamples.count) / sampleRate
        )
    }

    func buildDraftSegmentsFromTranscription(
        _ segments: [LocalPipelineBaseSegment],
        timingGuideSegments: [LocalPipelineBaseSegment],
        totalDuration: TimeInterval
    ) -> [LocalPipelineDraftSegment] {
        var blocks: [LocalPipelineDraftSegment] = []
        var current: [LocalPipelineBaseSegment] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            let blockID = String(format: "block-%05d", blocks.count + 1)
            let text = current.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                current.removeAll()
                return
            }
            blocks.append(
                LocalPipelineDraftSegment(
                    segmentId: blockID,
                    chunkId: current.first?.segmentId.components(separatedBy: "-seg-").first ?? blockID,
                    startTime: current.first?.start ?? 0,
                    endTime: current.last?.end ?? 0,
                    text: text,
                    sourceSegmentIDs: current.map(\.segmentId)
                )
            )
            current.removeAll()
        }

        for segment in segments {
            if current.isEmpty {
                current.append(segment)
            } else if shouldStartNewDraftBlock(current: current, next: segment) {
                flushCurrent()
                current.append(segment)
            } else {
                current.append(segment)
            }

            let duration = (current.last?.end ?? segment.end) - (current.first?.start ?? segment.start)
            if current.count >= LocalPipelineServiceConfig.draftMaxLines
                || duration >= LocalPipelineServiceConfig.draftTargetDuration
                || (endsSentence(segment.text) && duration >= 2.0) {
                flushCurrent()
            }
        }

        flushCurrent()
        guard !blocks.isEmpty, !timingGuideSegments.isEmpty else {
            return blocks
        }

        let guideRegions = makeGuideRegions(from: timingGuideSegments, speechRegions: [])
        guard !guideRegions.isEmpty else {
            return blocks
        }

        let entries = blocks.enumerated().map { index, block in
            ReferenceLyricEntry(
                text: block.text,
                sourceStart: block.startTime,
                sourceEnd: block.endTime,
                sourceIndex: index
            )
        }
        let matches = alignReferenceEntries(entries, to: guideRegions)
        let retimed = blocks.enumerated().map { index, block in
            var retimedBlock = block
            let timing = referenceTiming(
                for: matches[index],
                index: index,
                matches: matches,
                coarseTiming: (block.startTime, block.endTime)
            )
            retimedBlock.startTime = timing.start
            retimedBlock.endTime = timing.end
            retimedBlock.sourceSegmentIDs = matches[index].region?.sourceSegmentIDs ?? block.sourceSegmentIDs
            retimedBlock.alignmentSearchStart = max(0, timing.start - LocalPipelineServiceConfig.txtAlignmentPadding)
            retimedBlock.alignmentSearchEnd = min(totalDuration, timing.end + LocalPipelineServiceConfig.txtAlignmentPadding)
            return retimedBlock
        }

        return enforceReferenceDraftOrder(retimed, totalDuration: totalDuration)
    }

    func buildDraftSegmentsFromReferenceLyrics(
        _ lyricsReference: LocalLyricsReferenceInput,
        guideSegments: [LocalPipelineBaseSegment],
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double,
        logger: RunLogger,
        runId: String
    ) throws -> [LocalPipelineDraftSegment] {
        let entries = lyricsReference.entries.filter { !$0.text.isEmpty }
        guard !entries.isEmpty else { return [] }

        switch lyricsReference.sourceKind {
        case .srt where entries.allSatisfy({ $0.sourceStart != nil && $0.sourceEnd != nil }):
            return buildDraftSegmentsFromReferenceSRT(
                entries,
                guideSegments: guideSegments,
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate
            )
        case .plainText, .srt:
            return try buildDraftSegmentsFromReferenceText(
                entries,
                guideSegments: guideSegments,
                normalizedAudioURL: normalizedAudioURL,
                normalizedSamples: normalizedSamples,
                sampleRate: sampleRate,
                logger: logger,
                runId: runId
            )
        }
    }

    func buildDraftSegmentsFromReferenceSRT(
        _ entries: [ReferenceLyricEntry],
        guideSegments: [LocalPipelineBaseSegment],
        normalizedSamples: [Float],
        sampleRate: Double
    ) -> [LocalPipelineDraftSegment] {
        let totalDuration = Double(normalizedSamples.count) / sampleRate

        return entries.enumerated().compactMap { index, entry in
            guard let sourceStart = entry.sourceStart else { return nil }
            let sourceEnd = max(entry.sourceEnd ?? (sourceStart + expectedDuration(for: entry.text)), sourceStart + 0.35)
            let corrected = gentlyCorrectSRTReferenceTiming(
                start: sourceStart,
                end: sourceEnd,
                totalDuration: totalDuration,
                samples: normalizedSamples,
                sampleRate: sampleRate
            )
            let sourceIDs = guideSegments
                .filter { $0.end >= corrected.start - 0.4 && $0.start <= corrected.end + 0.4 }
                .map(\.segmentId)

            return LocalPipelineDraftSegment(
                segmentId: String(format: "block-%05d", index + 1),
                chunkId: "lyrics-reference-srt",
                startTime: corrected.start,
                endTime: corrected.end,
                text: entry.text,
                sourceSegmentIDs: sourceIDs,
                referenceSourceKind: .srt,
                alignmentSearchStart: max(0, sourceStart - LocalPipelineServiceConfig.referenceSRTSearchPad),
                alignmentSearchEnd: min(totalDuration, sourceEnd + LocalPipelineServiceConfig.referenceSRTSearchPad)
            )
        }
    }

    func calculateFFmpegNoiseThreshold(
        samples: [Float],
        sampleRate: Double
    ) -> String {
        guard !samples.isEmpty else { return "-32dB" }
        let rmsValues = calculateRMSProfile(samples: samples, sampleRate: sampleRate)
        let avgRMS = rmsValues.isEmpty ? 0.001 : rmsValues.reduce(0, +) / Double(rmsValues.count)
        let dbLevel = 20.0 * log10(max(avgRMS, 0.00001))
        // 無音閾値をやや厳しめにして短い途切れを無音と判断しやすくする
        let clampedDB = max(dbLevel - 12, -40.0)
        return String(format: "%.0fdB", clampedDB)
    }

    func calculateRMSProfile(
        samples: [Float],
        sampleRate: Double
    ) -> [Double] {
        let windowSize = max(1, Int(sampleRate * 0.02))
        var rmsValues: [Double] = []
        var index = 0
        while index + windowSize <= samples.count {
            let window = samples[index..<(index + windowSize)]
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            rmsValues.append(Double(rms))
            index += windowSize
        }
        return rmsValues
    }

    func calculateTxtReferenceSpeechMergeGap(
        texts: [String],
        totalDuration: TimeInterval
    ) -> TimeInterval {
        guard !texts.isEmpty else { return 0.7 }
        let avgCharactersPerLine = Double(texts.reduce(0) { $0 + $1.count }) / Double(texts.count)
        let estimatedTempo = max(0.1, avgCharactersPerLine / 25.0)
        return min(1.2, 0.5 + (estimatedTempo * 0.3))
    }

    func buildDraftSegmentsFromReferenceText(
        _ entries: [ReferenceLyricEntry],
        guideSegments: [LocalPipelineBaseSegment],
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double,
        logger: RunLogger,
        runId: String
    ) throws -> [LocalPipelineDraftSegment] {
        var speechRegions =
            detectSpeechRegionsWithFFmpeg(audioURL: normalizedAudioURL, normalizedSamples: normalizedSamples, sampleRate: sampleRate)
            ?? detectSpeechRegions(samples: normalizedSamples, sampleRate: sampleRate)
        // 内部に長い無音がある場合は分割して扱う
        let before = speechRegions
        speechRegions = splitSpeechRegionsOnInternalSilence(speechRegions, samples: normalizedSamples, sampleRate: sampleRate)
        try? logger.log(
            runId: runId,
            stage: LocalPipelinePhase.chunking.rawValue,
            level: .info,
            message: "speechRegions split: \(before.count) -> \(speechRegions.count)",
            engineType: .localPipeline
        )
        let totalDuration = Double(normalizedSamples.count) / sampleRate
        let timings: [(start: TimeInterval, end: TimeInterval)]
        if speechRegions.isEmpty {
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.chunking.rawValue,
                level: .warn,
                message: "reference lyrics VAD produced no speech regions; using coarse sequential timing",
                engineType: .localPipeline
            )
            timings = coarseSequentialReferenceTimings(
                for: entries,
                speechRegions: speechRegions,
                guideSegments: guideSegments,
                totalDuration: totalDuration
            )
        } else {
            timings = sequentialReferenceTimingsAcrossSpeechRegions(
                texts: entries.map(\.text),
                speechRegions: speechRegions,
                totalDuration: totalDuration,
                samples: normalizedSamples,
                sampleRate: sampleRate
            )
        }

        let draftSegments = entries.enumerated().map { index, entry in
            let timing = timings[index]
            return LocalPipelineDraftSegment(
                segmentId: String(format: "block-%05d", index + 1),
                chunkId: "lyrics-reference-text",
                startTime: timing.start,
                endTime: timing.end,
                text: entry.text,
                sourceSegmentIDs: [],
                referenceSourceKind: .plainText,
                alignmentSearchStart: max(0, timing.start - LocalPipelineServiceConfig.txtAlignmentPadding),
                alignmentSearchEnd: min(totalDuration, timing.end + LocalPipelineServiceConfig.txtAlignmentPadding)
            )
        }
        let orderedDraftSegments = enforceReferenceDraftOrder(
            draftSegments,
            totalDuration: totalDuration
        )

        return orderedDraftSegments
    }

    func detectSpeechRegionsWithFFmpeg(
        audioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double
    ) -> [SpeechRegion]? {
        let totalDuration = Double(normalizedSamples.count) / sampleRate
        let noiseThreshold = calculateFFmpegNoiseThreshold(samples: normalizedSamples, sampleRate: sampleRate)
        // 無音継続時間をやや長めにして短い途切れを無音に含めやすくする
        let silenceDuration = 0.6

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg",
            "-i", audioURL.path,
            "-af", "silencedetect=noise=\(noiseThreshold):d=\(silenceDuration)",
            "-f", "null",
            "-"
        ]
        process.environment = buildProcessEnvironment(extraExecutableURLs: [])

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let stderrText = String(data: stderrData, encoding: .utf8) else {
            return nil
        }

        let silenceStarts = regexCaptureValues(in: stderrText, pattern: #"silence_start:\s*([0-9.]+)"#).compactMap(Double.init)
        let silenceEnds = regexCaptureValues(in: stderrText, pattern: #"silence_end:\s*([0-9.]+)"#).compactMap(Double.init)
        guard !silenceStarts.isEmpty, silenceStarts.count == silenceEnds.count else {
            return nil
        }

        var speechRegions: [SpeechRegion] = []
        var cursor: TimeInterval = 0
        for (silenceStart, silenceEnd) in zip(silenceStarts, silenceEnds) {
            if silenceStart > cursor + LocalPipelineServiceConfig.vadMinRegionDuration {
                speechRegions.append(SpeechRegion(start: cursor, end: silenceStart))
            }
            cursor = max(cursor, silenceEnd)
        }
        if totalDuration > cursor + LocalPipelineServiceConfig.vadMinRegionDuration {
            speechRegions.append(SpeechRegion(start: cursor, end: totalDuration))
        }

        let mergeGap = calculateTxtReferenceSpeechMergeGap(texts: [], totalDuration: totalDuration)
        return mergeSpeechRegions(
            speechRegions.filter { $0.end - $0.start >= LocalPipelineServiceConfig.vadMinRegionDuration },
            maxGap: mergeGap
        )
    }

    func sequentialReferenceTimingsAcrossSpeechRegions(
        texts: [String],
        speechRegions: [SpeechRegion],
        totalDuration: TimeInterval,
        samples: [Float],
        sampleRate: Double
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !texts.isEmpty else { return [] }
        guard !speechRegions.isEmpty else {
            return distributedReferenceTimings(
                texts: texts,
                spanStart: 0,
                spanEnd: totalDuration,
                totalDuration: totalDuration
            )
        }

        let totalSpeechDuration = speechRegions.reduce(0) { $0 + max(0, $1.end - $1.start) }
        guard totalSpeechDuration > 0.01 else {
            return distributedReferenceTimings(
                texts: texts,
                spanStart: speechRegions.first?.start ?? 0,
                spanEnd: speechRegions.last?.end ?? totalDuration,
                totalDuration: totalDuration
            )
        }

        let durations = texts.map(referenceTimingExpectedDuration(for:))
        let totalWeight = max(durations.reduce(0, +), 0.001)
        var cumulativeSpeech: [TimeInterval] = [0]
        cumulativeSpeech.reserveCapacity(speechRegions.count + 1)
        for region in speechRegions {
            cumulativeSpeech.append(cumulativeSpeech.last! + max(0, region.end - region.start))
        }

        func speechRegionIndex(for offset: TimeInterval) -> Int {
            let clampedOffset = clamp(offset, min: 0, max: totalSpeechDuration)
            for index in speechRegions.indices {
                let regionEndOffset = cumulativeSpeech[index + 1]
                if clampedOffset <= regionEndOffset || index == speechRegions.count - 1 {
                    return index
                }
            }
            return max(0, speechRegions.count - 1)
        }

        var lineIndexesByRegion = Array(repeating: [Int](), count: speechRegions.count)
        var consumedWeight: TimeInterval = 0
        for (index, weight) in durations.enumerated() {
            let midpointWeight = consumedWeight + (weight / 2)
            let midpointOffset = totalSpeechDuration * (midpointWeight / totalWeight)
            let regionIndex = speechRegionIndex(for: midpointOffset)
            lineIndexesByRegion[regionIndex].append(index)
            consumedWeight += weight
        }

        var timings = Array(repeating: (start: 0.0, end: 0.0), count: texts.count)
        for (regionIndex, lineIndexes) in lineIndexesByRegion.enumerated() {
            guard !lineIndexes.isEmpty else { continue }
            let region = speechRegions[regionIndex]
            let localTexts = lineIndexes.map { texts[$0] }
            let localTimings = refineReferenceTimingsWithinSpeechRegion(
                texts: localTexts,
                region: region,
                totalDuration: totalDuration,
                samples: samples,
                sampleRate: sampleRate
            )
            for (localIndex, lineIndex) in lineIndexes.enumerated() {
                timings[lineIndex] = localTimings[localIndex]
            }
        }

        return timings.enumerated().map { index, timing in
            let nextStart = index + 1 < timings.count ? timings[index + 1].start : nil
            let safeEnd = nextStart.map { min(timing.end, $0) } ?? timing.end
            return (timing.start, max(timing.start + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, safeEnd))
        }
    }

    func refineReferenceTimingsWithinSpeechRegion(
        texts: [String],
        region: SpeechRegion,
        totalDuration: TimeInterval,
        samples: [Float],
        sampleRate: Double
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let durations = texts.map(referenceTimingExpectedDuration(for:))
        guard texts.count > 1 else {
            return distributedReferenceTimings(
                durations: durations,
                spanStart: region.start,
                spanEnd: region.end,
                totalDuration: totalDuration
            )
        }

        let coarseTimings = distributedReferenceTimingsAcrossEnergy(
            durations: durations,
            region: region,
            totalDuration: totalDuration,
            samples: samples,
            sampleRate: sampleRate,
            windowDuration: LocalPipelineServiceConfig.txtReferenceEnergyWindowDuration,
            stepDuration: LocalPipelineServiceConfig.txtReferenceEnergyStepDuration
        ) ?? distributedReferenceTimings(
            durations: durations,
            spanStart: region.start,
            spanEnd: region.end,
            totalDuration: totalDuration
        )

        var boundaries: [TimeInterval] = [region.start]
        for index in 0..<(texts.count - 1) {
            let target = coarseTimings[index].end
            boundaries.append(
                findQuietBoundaryNear(
                    target: target,
                    minTime: boundaries.last ?? region.start,
                    maxTime: region.end,
                    samples: samples,
                    sampleRate: sampleRate,
                    windowDuration: LocalPipelineServiceConfig.txtReferenceBoundaryWindowDuration,
                    stepDuration: LocalPipelineServiceConfig.txtReferenceBoundaryStepDuration
                ) ?? target
            )
        }
        boundaries.append(region.end)

        var timings: [(start: TimeInterval, end: TimeInterval)] = []
        timings.reserveCapacity(texts.count)
        for index in 0..<texts.count {
            let start = boundaries[index]
            let end = max(boundaries[index + 1], start + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration)
            timings.append((start, end))
        }
        return timings
    }

    func distributedReferenceTimingsAcrossEnergy(
        durations: [TimeInterval],
        region: SpeechRegion,
        totalDuration: TimeInterval,
        samples: [Float],
        sampleRate: Double,
        windowDuration: TimeInterval = 0.02,
        stepDuration: TimeInterval = 0.01
    ) -> [(start: TimeInterval, end: TimeInterval)]? {
        guard durations.count > 1 else { return nil }

        let windowSize = max(1, Int(sampleRate * windowDuration))
        let stepSize = max(1, Int(sampleRate * stepDuration))
        let startIndex = max(0, Int(region.start * sampleRate))
        let endIndex = min(samples.count, Int(region.end * sampleRate))
        guard endIndex > startIndex + windowSize else { return nil }

        var points: [(time: TimeInterval, energy: Double)] = []
        points.reserveCapacity(max(1, (endIndex - startIndex) / stepSize))

        var index = startIndex
        while index + windowSize <= endIndex {
            let window = samples[index..<(index + windowSize)]
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            let time = Double(index + windowSize / 2) / sampleRate
            points.append((time: time, energy: Double(max(rms, 0.00005))))
            index += stepSize
        }

        let totalEnergy = points.reduce(0.0) { $0 + $1.energy }
        guard totalEnergy > 0.0001 else { return nil }

        let totalWeight = max(durations.reduce(0, +), 0.001)
        var cumulativeWeight = 0.0
        var boundaries: [TimeInterval] = [region.start]

        for weight in durations.dropLast() {
            cumulativeWeight += weight
            let targetEnergy = totalEnergy * (cumulativeWeight / totalWeight)
            var runningEnergy = 0.0
            var bestTime = points.last?.time ?? region.end
            for point in points {
                runningEnergy += point.energy
                if runningEnergy >= targetEnergy {
                    bestTime = point.time
                    break
                }
            }
            boundaries.append(clamp(bestTime, min: region.start, max: region.end))
        }
        boundaries.append(region.end)

        var timings: [(start: TimeInterval, end: TimeInterval)] = []
        timings.reserveCapacity(durations.count)
        for idx in durations.indices {
            let start = idx == 0 ? region.start : max(boundaries[idx], timings.last?.end ?? region.start)
            let proposedEnd = idx == durations.count - 1 ? region.end : boundaries[idx + 1]
            let end = max(start + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, proposedEnd)
            timings.append((start, min(region.end, end)))
        }

        guard timings.allSatisfy({ $0.end > $0.start }) else { return nil }
        return timings
    }

    func findQuietBoundaryNear(
        target: TimeInterval,
        minTime: TimeInterval,
        maxTime: TimeInterval,
        samples: [Float],
        sampleRate: Double,
        searchRadius: TimeInterval = 0.25,
        distanceWeight: Float = 0.05,
        windowDuration: TimeInterval = 0.02,
        stepDuration: TimeInterval = 0.01
    ) -> TimeInterval? {
        let minimumSpacing: TimeInterval = LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration

        let lowerBound = max(minTime + minimumSpacing, target - searchRadius)
        let upperBound = min(maxTime - minimumSpacing, target + searchRadius)
        guard upperBound > lowerBound else { return nil }

        let windowSize = max(1, Int(sampleRate * windowDuration))
        let stepSize = max(1, Int(sampleRate * stepDuration))
        let startIndex = max(0, Int(lowerBound * sampleRate))
        let endIndex = min(samples.count - 1, Int(upperBound * sampleRate))
        guard endIndex > startIndex + windowSize else { return nil }

        var bestTime: TimeInterval?
        var bestScore = Float.greatestFiniteMagnitude

        var index = startIndex
        while index + windowSize < endIndex {
            let window = samples[index..<(index + windowSize)]
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            let time = Double(index + windowSize / 2) / sampleRate
            let score = rms + Float(abs(time - target)) * distanceWeight
            if score < bestScore {
                bestScore = score
                bestTime = time
            }
            index += stepSize
        }

        return bestTime
    }

    func gentlyCorrectSRTReferenceTiming(
        start: TimeInterval,
        end: TimeInterval,
        totalDuration: TimeInterval,
        samples: [Float],
        sampleRate: Double
    ) -> (start: TimeInterval, end: TimeInterval) {
        let searchStart = max(0, start - LocalPipelineServiceConfig.referenceSRTSearchPad)
        let searchEnd = min(totalDuration, end + LocalPipelineServiceConfig.referenceSRTSearchPad)
        let searchSamples = extractSamples(from: samples, sampleRate: sampleRate, start: searchStart, end: searchEnd)
        guard !searchSamples.isEmpty else { return (start, end) }

        let windowSize = max(1, Int(sampleRate * LocalPipelineServiceConfig.vadWindowSize))
        let leading = firstActiveWindow(in: searchSamples, windowSize: windowSize)
        let trailing = lastActiveWindow(in: searchSamples, windowSize: windowSize)
        guard let leading, let trailing, trailing > leading else { return (start, end) }

        let candidateStart = searchStart + max(0, Double(leading - windowSize / 2) / sampleRate)
        let candidateEnd = searchStart + min(Double(searchSamples.count), Double(trailing + windowSize / 2)) / sampleRate
        let boundedStart = clamp(candidateStart, min: max(0, start - LocalPipelineServiceConfig.referenceSRTMaxShift), max: min(totalDuration, start + LocalPipelineServiceConfig.referenceSRTMaxShift))
        let boundedEnd = clamp(candidateEnd, min: max(0, end - LocalPipelineServiceConfig.referenceSRTMaxShift), max: min(totalDuration, end + LocalPipelineServiceConfig.referenceSRTMaxShift))
        guard boundedEnd > boundedStart else { return (start, end) }
        return (boundedStart, max(boundedStart + 0.35, boundedEnd))
    }

    func detectSpeechRegions(samples: [Float], sampleRate: Double) -> [SpeechRegion] {
        guard !samples.isEmpty else { return [] }
        let windowSize = max(1, Int(sampleRate * LocalPipelineServiceConfig.vadWindowSize))
        var profile: [(rms: Float, peak: Float)] = []
        profile.reserveCapacity(max(1, samples.count / windowSize))

        for index in stride(from: 0, to: samples.count, by: windowSize) {
            let end = min(index + windowSize, samples.count)
            let window = samples[index..<end]
            let peak = window.map { abs($0) }.max() ?? 0
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            profile.append((rms, peak))
        }

        let rmsValues = profile.map(\.rms)
        guard let maxRMS = rmsValues.max(), maxRMS >= LocalPipelineServiceConfig.localWaveformAlignmentConfig.minVolumeAbsolute else { return [] }
        let threshold = calculateAdaptiveThreshold(rmsValues)
        var active = profile.map { $0.peak >= 0.015 || $0.rms >= threshold }
        fillShortGaps(&active, maxGapFrames: max(1, Int(LocalPipelineServiceConfig.vadMinGapFill / LocalPipelineServiceConfig.vadWindowSize)))

        var regions: [SpeechRegion] = []
        var regionStart: Int?
        for index in active.indices {
            if active[index] {
                regionStart = regionStart ?? index
            } else if let currentRegionStart = regionStart {
                let region = makeSpeechRegion(startIndex: currentRegionStart, endIndex: index, windowSize: windowSize, sampleRate: sampleRate)
                if region.end - region.start >= LocalPipelineServiceConfig.vadMinRegionDuration {
                    regions.append(region)
                }
                regionStart = nil
            }
        }

        if let currentRegionStart = regionStart {
            let region = makeSpeechRegion(startIndex: currentRegionStart, endIndex: active.count, windowSize: windowSize, sampleRate: sampleRate)
            if region.end - region.start >= LocalPipelineServiceConfig.vadMinRegionDuration {
                regions.append(region)
            }
        }

        return mergeSpeechRegions(regions)
    }

    func makeGuideRegions(
        from guideSegments: [LocalPipelineBaseSegment],
        speechRegions: [SpeechRegion]
    ) -> [GuideRegion] {
        guard !guideSegments.isEmpty else { return [] }
        return makeTimingGuideAnchors(from: guideSegments, speechRegions: speechRegions).map { anchor in
            return GuideRegion(
                start: anchor.start,
                end: anchor.end,
                text: anchor.text,
                sourceSegmentIDs: anchor.sourceSegmentIDs
            )
        }
    }

    func makeTimingGuideAnchors(
        from guideSegments: [LocalPipelineBaseSegment],
        speechRegions: [SpeechRegion]
    ) -> [TimingGuideAnchor] {
        guideSegments.compactMap { segment in
            let trimmed = trimmedTimingGuideRange(for: segment, speechRegions: speechRegions)
            guard trimmed.end > trimmed.start + 0.02 else { return nil }
            return TimingGuideAnchor(
                start: trimmed.start,
                end: trimmed.end,
                text: segment.text,
                confidence: segment.confidence,
                sourceSegmentIDs: [segment.segmentId]
            )
        }
    }

    func trimmedTimingGuideRange(
        for segment: LocalPipelineBaseSegment,
        speechRegions: [SpeechRegion]
    ) -> (start: TimeInterval, end: TimeInterval) {
        guard !speechRegions.isEmpty else {
            return (segment.start, segment.end)
        }

        let overlapping = speechRegions.filter { region in
            region.end >= segment.start - 0.2 && region.start <= segment.end + 0.2
        }
        guard !overlapping.isEmpty else {
            return (segment.start, segment.end)
        }

        let start = max(segment.start, overlapping.map(\.start).min() ?? segment.start)
        let end = min(segment.end, overlapping.map(\.end).max() ?? segment.end)
        guard end > start + 0.02 else {
            return (segment.start, segment.end)
        }
        return (start, end)
    }

    func alignReferenceEntries(
        _ entries: [ReferenceLyricEntry],
        to guideRegions: [GuideRegion]
    ) -> [ReferenceAlignmentMatch] {
        let lineCount = entries.count
        let regionCount = guideRegions.count
        guard lineCount > 0 else { return [] }

        var states = Array(
            repeating: Array<AlignmentState?>(repeating: nil, count: regionCount + 1),
            count: lineCount + 1
        )
        var backtrack = Array(
            repeating: Array<(previousI: Int, previousJ: Int, matchedRegionCount: Int, unmatched: Bool)?>(repeating: nil, count: regionCount + 1),
            count: lineCount + 1
        )
        states[0][0] = AlignmentState(cost: 0, lastMatchedEnd: nil)

        func updateState(
            i: Int,
            j: Int,
            cost: Double,
            lastMatchedEnd: TimeInterval?,
            previousI: Int,
            previousJ: Int,
            matchedRegionCount: Int,
            unmatched: Bool
        ) {
            let candidate = AlignmentState(cost: cost, lastMatchedEnd: lastMatchedEnd)
            if let existing = states[i][j], existing.cost <= candidate.cost {
                return
            }
            states[i][j] = candidate
            backtrack[i][j] = (previousI, previousJ, matchedRegionCount, unmatched)
        }

        for i in 0...lineCount {
            for j in 0...regionCount {
                guard let state = states[i][j] else { continue }

                if j < regionCount {
                    updateState(
                        i: i,
                        j: j + 1,
                        cost: state.cost + LocalPipelineServiceConfig.skippedRegionPenalty,
                        lastMatchedEnd: state.lastMatchedEnd,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 0,
                        unmatched: false
                    )
                }

                guard i < lineCount else { continue }

                updateState(
                    i: i + 1,
                    j: j,
                    cost: state.cost + LocalPipelineServiceConfig.unmatchedLinePenalty,
                    lastMatchedEnd: state.lastMatchedEnd,
                    previousI: i,
                    previousJ: j,
                    matchedRegionCount: 0,
                    unmatched: true
                )

                if j < regionCount {
                    let region = guideRegions[j]
                    updateState(
                        i: i + 1,
                        j: j + 1,
                        cost: state.cost + costToMatch(entry: entries[i], region: region, previousEnd: state.lastMatchedEnd),
                        lastMatchedEnd: region.end,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 1,
                        unmatched: false
                    )
                }

                if j + 1 < regionCount {
                    let combined = combineGuideRegions(guideRegions[j], guideRegions[j + 1])
                    updateState(
                        i: i + 1,
                        j: j + 2,
                        cost: state.cost + costToMatch(entry: entries[i], region: combined, previousEnd: state.lastMatchedEnd),
                        lastMatchedEnd: combined.end,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 2,
                        unmatched: false
                    )
                }

                if j + 2 < regionCount {
                    let combined = combineGuideRegions(
                        combineGuideRegions(guideRegions[j], guideRegions[j + 1]),
                        guideRegions[j + 2]
                    )
                    updateState(
                        i: i + 1,
                        j: j + 3,
                        cost: state.cost + costToMatch(entry: entries[i], region: combined, previousEnd: state.lastMatchedEnd),
                        lastMatchedEnd: combined.end,
                        previousI: i,
                        previousJ: j,
                        matchedRegionCount: 3,
                        unmatched: false
                    )
                }
            }
        }

        let bestEndIndex = (0...regionCount)
            .compactMap { index in states[lineCount][index].map { (index, $0.cost) } }
            .min(by: { $0.1 < $1.1 })?
            .0 ?? 0

        var matches = Array<ReferenceAlignmentMatch?>(repeating: nil, count: lineCount)
        var i = lineCount
        var j = bestEndIndex

        while i > 0 {
            guard let step = backtrack[i][j] else {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: nil, wasUnmatched: true)
                i -= 1
                continue
            }

            if step.unmatched {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: nil, wasUnmatched: true)
            } else if step.matchedRegionCount == 1 {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: guideRegions[step.previousJ], wasUnmatched: false)
            } else if step.matchedRegionCount == 2 {
                matches[i - 1] = ReferenceAlignmentMatch(
                    entry: entries[i - 1],
                    region: combineGuideRegions(guideRegions[step.previousJ], guideRegions[step.previousJ + 1]),
                    wasUnmatched: false
                )
            } else if step.matchedRegionCount == 3 {
                matches[i - 1] = ReferenceAlignmentMatch(
                    entry: entries[i - 1],
                    region: combineGuideRegions(
                        combineGuideRegions(guideRegions[step.previousJ], guideRegions[step.previousJ + 1]),
                        guideRegions[step.previousJ + 2]
                    ),
                    wasUnmatched: false
                )
            } else {
                matches[i - 1] = ReferenceAlignmentMatch(entry: entries[i - 1], region: nil, wasUnmatched: true)
            }

            i = step.previousI
            j = step.previousJ
        }

        return matches.compactMap { $0 }
    }

    func referenceTiming(
        for match: ReferenceAlignmentMatch,
        index: Int,
        matches: [ReferenceAlignmentMatch],
        coarseTiming: (start: TimeInterval, end: TimeInterval)
    ) -> (start: TimeInterval, end: TimeInterval) {
        if let region = match.region {
            return (region.start, max(region.end, region.start + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration))
        }

        let previousMatched = matches[..<index].reversed().first(where: { $0.region != nil })?.region
        let nextMatched = matches.dropFirst(index + 1).first(where: { $0.region != nil })?.region

        if let previousMatched, let nextMatched,
           let fitted = fitReferenceTiming(
               preferredStart: coarseTiming.start,
               preferredDuration: coarseTiming.end - coarseTiming.start,
               minStart: previousMatched.end + 0.08,
               maxEnd: nextMatched.start - 0.08
           ) {
            return fitted
        }

        if let nextMatched,
           let fitted = fitReferenceTiming(
               preferredStart: coarseTiming.start,
               preferredDuration: coarseTiming.end - coarseTiming.start,
               minStart: max(0, nextMatched.start - max(coarseTiming.end - coarseTiming.start, LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration) - 0.08),
               maxEnd: nextMatched.start - 0.08
           ) {
            return fitted
        }

        if let previousMatched,
           let fitted = fitReferenceTiming(
               preferredStart: max(coarseTiming.start, previousMatched.end + 0.08),
               preferredDuration: coarseTiming.end - coarseTiming.start,
               minStart: previousMatched.end + 0.08,
               maxEnd: max(previousMatched.end + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, coarseTiming.end)
           ) {
            return fitted
        }

        return coarseTiming
    }

    func fitReferenceTiming(
        preferredStart: TimeInterval,
        preferredDuration: TimeInterval,
        minStart: TimeInterval,
        maxEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let minimumDuration = LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
        guard maxEnd - minStart >= minimumDuration else { return nil }

        let duration = max(minimumDuration, preferredDuration)
        let start = min(max(preferredStart, minStart), maxEnd - minimumDuration)
        let end = min(maxEnd, max(start + minimumDuration, start + duration))
        guard end > start else { return nil }
        return (start, end)
    }

    func coarseSequentialReferenceTimings(
        for entries: [ReferenceLyricEntry],
        speechRegions: [SpeechRegion],
        guideSegments: [LocalPipelineBaseSegment],
        totalDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        let spanStart: TimeInterval
        let spanEnd: TimeInterval

        if let firstSpeech = speechRegions.first, let lastSpeech = speechRegions.last {
            spanStart = firstSpeech.start
            spanEnd = lastSpeech.end
        } else if let firstGuide = guideSegments.map(\.start).min(),
                  let lastGuide = guideSegments.map(\.end).max() {
            spanStart = firstGuide
            spanEnd = lastGuide
        } else {
            spanStart = 0
            spanEnd = totalDuration
        }

        return distributedReferenceTimings(
            durations: entries.map { referenceTimingExpectedDuration(for: $0.text) },
            spanStart: spanStart,
            spanEnd: spanEnd,
            totalDuration: totalDuration
        )
    }

    func distributedReferenceTimings(
        texts: [String],
        spanStart: TimeInterval,
        spanEnd: TimeInterval,
        totalDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        distributedReferenceTimings(
            durations: texts.map(expectedDuration(for:)),
            spanStart: spanStart,
            spanEnd: spanEnd,
            totalDuration: totalDuration
        )
    }

    func distributedReferenceTimings(
        durations: [TimeInterval],
        spanStart: TimeInterval,
        spanEnd: TimeInterval,
        totalDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !durations.isEmpty else { return [] }

        let minimumDuration = LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
        let minimumTotalDuration = Double(durations.count) * minimumDuration
        var start = max(0, spanStart)
        var end = min(totalDuration, max(spanEnd, start + minimumTotalDuration))

        if end - start < minimumTotalDuration {
            start = max(0, min(start, totalDuration - minimumTotalDuration))
            end = min(totalDuration, max(start + minimumTotalDuration, spanEnd))
        }
        if end - start < minimumTotalDuration {
            start = 0
            end = max(totalDuration, minimumTotalDuration)
        }

        let totalWeight = max(durations.reduce(0, +), 0.001)
        var cursor = start
        var timings: [(start: TimeInterval, end: TimeInterval)] = []
        timings.reserveCapacity(durations.count)

        for (index, weight) in durations.enumerated() {
            let remainingMinimum = Double(durations.count - index - 1) * minimumDuration
            let remainingWindow = max(minimumDuration, end - cursor - remainingMinimum)
            let proposedDuration = max(minimumDuration, (end - start) * (weight / totalWeight))
            let duration = min(proposedDuration, remainingWindow)
            let segmentEnd = index == durations.count - 1 ? end : min(end, cursor + duration)
            timings.append((cursor, max(cursor + minimumDuration, segmentEnd)))
            cursor = max(cursor + minimumDuration, segmentEnd)
        }

        if let lastIndex = timings.indices.last {
            timings[lastIndex].end = max(timings[lastIndex].start + minimumDuration, end)
        }

        return timings.enumerated().map { index, timing in
            let nextStart = index + 1 < timings.count ? timings[index + 1].start : nil
            let safeEnd = nextStart.map { min(timing.end, $0) } ?? timing.end
            return (timing.start, max(timing.start + minimumDuration, safeEnd))
        }
    }

    func enforceReferenceDraftOrder(
        _ segments: [LocalPipelineDraftSegment],
        totalDuration: TimeInterval
    ) -> [LocalPipelineDraftSegment] {
        guard !segments.isEmpty else { return [] }

        var ordered: [LocalPipelineDraftSegment] = []
        ordered.reserveCapacity(segments.count)

        for segment in segments {
            var adjusted = segment
            let minimumStart = ordered.last?.endTime ?? 0

            if adjusted.startTime < minimumStart {
                let underflow = minimumStart - adjusted.startTime
                if underflow <= LocalPipelineServiceConfig.referenceDraftMaxOverlap {
                    // 小さな重なりは許容して、全体の長さを崩さない
                    adjusted.startTime = segment.startTime
                } else {
                    adjusted.startTime = minimumStart
                }
            }

            adjusted.endTime = max(segment.endTime, adjusted.startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration)

            if adjusted.endTime > totalDuration {
                adjusted.endTime = max(adjusted.startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, totalDuration)
            }

            if adjusted.endTime <= adjusted.startTime {
                adjusted.endTime = adjusted.startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
            }

            adjusted.alignmentSearchStart = max(0, adjusted.startTime - LocalPipelineServiceConfig.txtAlignmentPadding)
            adjusted.alignmentSearchEnd = min(totalDuration, adjusted.endTime + LocalPipelineServiceConfig.txtAlignmentPadding)
            ordered.append(adjusted)
        }

        return ordered
    }

    func combineGuideRegions(_ lhs: GuideRegion, _ rhs: GuideRegion) -> GuideRegion {
        GuideRegion(
            start: min(lhs.start, rhs.start),
            end: max(lhs.end, rhs.end),
            text: joinSubtitleTexts(lhs.text, rhs.text),
            sourceSegmentIDs: lhs.sourceSegmentIDs + rhs.sourceSegmentIDs
        )
    }

    func costToMatch(
        entry: ReferenceLyricEntry,
        region: GuideRegion,
        previousEnd: TimeInterval?
    ) -> Double {
        let similarity = longestCommonSubsequenceRatio(normalizedText(entry.text), normalizedText(region.text))
        let similarityCost = (1 - similarity) * 4.0
        let expected = expectedDuration(for: entry.text)
        let durationCost = abs((region.end - region.start) - expected) / max(expected, 0.8)
        let gapCost: Double
        if let previousEnd {
            let gap = max(0, region.start - previousEnd)
            gapCost = gap > 1.8 ? (gap - 1.8) * 0.35 : gap * 0.08
        } else {
            gapCost = max(0, region.start - 0.2) * 0.04
        }
        return similarityCost + durationCost + gapCost
    }

    func expectedDuration(for text: String) -> TimeInterval {
        clamp(Double(max(normalizedText(text).count, 1)) * 0.22, min: 0.8, max: 6.0)
    }

    func referenceTimingExpectedDuration(for text: String) -> TimeInterval {
        expectedDuration(for: text)
    }

    func calculateAdaptiveThreshold(_ rmsValues: [Float]) -> Float {
        guard !rmsValues.isEmpty else { return LocalPipelineServiceConfig.localWaveformAlignmentConfig.minVolumeAbsolute }
        let sorted = rmsValues.sorted()
        let noiseFloor = sorted[Int(Float(sorted.count - 1) * 0.1)]
        let speechPeak = sorted[Int(Float(sorted.count - 1) * 0.9)]
        return max((noiseFloor + speechPeak) / 2, LocalPipelineServiceConfig.localWaveformAlignmentConfig.minVolumeAbsolute)
    }

    func fillShortGaps(_ active: inout [Bool], maxGapFrames: Int) {
        var gapStart: Int?
        for index in active.indices {
            if !active[index] {
                gapStart = gapStart ?? index
            } else if let currentGapStart = gapStart, index - currentGapStart <= maxGapFrames, currentGapStart > 0, active[currentGapStart - 1] {
                for fillIndex in currentGapStart..<index {
                    active[fillIndex] = true
                }
                gapStart = nil
            } else {
                gapStart = nil
            }
        }
    }

    func clearGap(_ gapStart: inout Int?) {
        gapStart = nil
    }

    func makeSpeechRegion(
        startIndex: Int,
        endIndex: Int,
        windowSize: Int,
        sampleRate: Double
    ) -> SpeechRegion {
        SpeechRegion(
            start: Double(startIndex * windowSize) / sampleRate,
            end: Double(endIndex * windowSize) / sampleRate
        )
    }

    func mergeSpeechRegions(_ regions: [SpeechRegion]) -> [SpeechRegion] {
        mergeSpeechRegions(regions, maxGap: LocalPipelineServiceConfig.vadMergeGap)
    }

    func mergeSpeechRegions(
        _ regions: [SpeechRegion],
        maxGap: TimeInterval
    ) -> [SpeechRegion] {
        guard !regions.isEmpty else { return [] }
        var merged: [SpeechRegion] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            guard let last = merged.last else {
                merged.append(region)
                continue
            }
            if region.start - last.end <= maxGap {
                merged[merged.count - 1] = SpeechRegion(start: last.start, end: max(last.end, region.end))
            } else {
                merged.append(region)
            }
        }
        return merged
    }

    func splitSpeechRegionsOnInternalSilence(
        _ regions: [SpeechRegion],
        samples: [Float],
        sampleRate: Double,
        minSilenceDuration: TimeInterval = 0.45
    ) -> [SpeechRegion] {
        guard !regions.isEmpty else { return [] }
        var result: [SpeechRegion] = []
        let windowSize = max(1, Int(sampleRate * 0.02))
        let stepSize = max(1, Int(sampleRate * 0.01))

        for region in regions {
            let startIndex = max(0, Int(region.start * sampleRate))
            let endIndex = min(samples.count, Int(region.end * sampleRate))
            guard endIndex > startIndex + windowSize else {
                result.append(region); continue
            }

            var energies: [Double] = []
            var idx = startIndex
            while idx + windowSize <= endIndex {
                let window = samples[idx..<(idx + windowSize)]
                let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
                energies.append(Double(max(rms, 1e-8)))
                idx += stepSize
            }
            guard !energies.isEmpty else { result.append(region); continue }

            let maxEnergy = energies.max() ?? 0.0
            let silenceThreshold = max(Double(LocalPipelineServiceConfig.localWaveformAlignmentConfig.minVolumeAbsolute), maxEnergy * 0.12)

            var silentRuns: [(Int, Int)] = []
            var runStart: Int? = nil
            for i in energies.indices {
                if energies[i] < silenceThreshold {
                    runStart = runStart ?? i
                } else if let s = runStart {
                    silentRuns.append((s, i - 1))
                    runStart = nil
                }
            }
            if let s = runStart { silentRuns.append((s, energies.count - 1)) }

            let validCuts = silentRuns.compactMap { (s, e) -> TimeInterval? in
                let dur = Double(e - s + 1) * Double(stepSize) / sampleRate
                guard dur >= minSilenceDuration else { return nil }
                let centerIndex = (s + e) / 2
                return region.start + Double(centerIndex * stepSize + windowSize / 2) / sampleRate
            }.sorted()

            if validCuts.isEmpty {
                result.append(region)
                continue
            }

            var segStart = region.start
            for cut in validCuts {
                let segEnd = clamp(cut, min: segStart + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, max: region.end)
                if segEnd - segStart >= LocalPipelineServiceConfig.vadMinRegionDuration {
                    result.append(SpeechRegion(start: segStart, end: segEnd))
                }
                segStart = segEnd
            }
            if region.end - segStart >= LocalPipelineServiceConfig.vadMinRegionDuration {
                result.append(SpeechRegion(start: segStart, end: region.end))
            }
        }

        return mergeSpeechRegions(result)
    }

    func clamp<T: Comparable>(_ value: T, min minimum: T, max maximum: T) -> T {
        Swift.max(minimum, Swift.min(maximum, value))
    }

    func longestCommonSubsequenceRatio(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var previous = Array(repeating: 0, count: right.count + 1)
        var current = Array(repeating: 0, count: right.count + 1)

        for leftCharacter in left {
            for (index, rightCharacter) in right.enumerated() {
                if leftCharacter == rightCharacter {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(current[index], previous[index + 1])
                }
            }
            swap(&previous, &current)
            current = Array(repeating: 0, count: right.count + 1)
        }

        return Double(previous[right.count]) / Double(min(left.count, right.count))
    }

    func regexCaptureValues(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }

    func shouldStartNewDraftBlock(
        current: [LocalPipelineBaseSegment],
        next: LocalPipelineBaseSegment
    ) -> Bool {
        guard let first = current.first, let last = current.last else { return false }
        let durationWithNext = next.end - first.start
        let gap = next.start - last.end
        if current.count >= LocalPipelineServiceConfig.draftMaxLines {
            return true
        }
        if durationWithNext > LocalPipelineServiceConfig.draftMaxDuration {
            return true
        }
        if gap > 1.2 {
            return true
        }
        if endsSentence(last.text) && normalizedText(next.text).count >= 4 {
            return true
        }
        return false
    }

    func refineSubtitlesForWaveform(
        _ subtitles: [SubtitleItem],
        fallbackSubtitles: [SubtitleItem],
        referenceSourceKind: LyricsReferenceSourceKind?,
        normalizedAudioURL: URL,
        normalizedSamples: [Float],
        sampleRate: Double
    ) async throws -> [SubtitleItem] {
        _ = normalizedAudioURL
        let hasReferenceLyrics = referenceSourceKind != nil
        let fallbackItems = fallbackSubtitles.isEmpty ? subtitles : fallbackSubtitles

        if referenceSourceKind == .plainText {
            let optimized = optimizeTXTReferenceSubtitles(
                subtitles,
                fallbackSubtitles: fallbackItems,
                samples: normalizedSamples,
                sampleRate: sampleRate
            )
            return optimized.filter { !isObviouslyGarbageTranscript($0.text, confidence: 0.75) }
        }

        let trimmed = zip(subtitles, fallbackItems).map { subtitle, fallback -> SubtitleItem in
            let adjusted = trimSubtitleToSpeech(
                subtitle,
                samples: normalizedSamples,
                sampleRate: sampleRate,
                searchPadding: 0,
                maxExpansion: .greatestFiniteMagnitude,
                windowDuration: 0.01
            )
            if hasReferenceLyrics && isSilentSubtitle(adjusted, samples: normalizedSamples, sampleRate: sampleRate) {
                return fallback
            }
            return adjusted
        }

        let boundaryAdjusted = hasReferenceLyrics
            ? rebalanceAdjacentReferenceBoundaries(trimmed, samples: normalizedSamples, sampleRate: sampleRate)
            : trimmed

        if hasReferenceLyrics {
            let ordered = normalizeReferenceSubtitleOrder(boundaryAdjusted)
            let filtered = ordered.filter { !isObviouslyGarbageTranscript($0.text, confidence: 0.75) }
            return finalizeReferenceTimeline(filtered)
        }

        let filtered = boundaryAdjusted.filter {
            !isObviouslyGarbageTranscript($0.text, confidence: 0.75)
                && !isSilentSubtitle($0, samples: normalizedSamples, sampleRate: sampleRate)
        }
        return mergeTinySubtitles(filtered, minimumDuration: LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration)
    }

    func rebalanceAdjacentReferenceBoundaries(
        _ subtitles: [SubtitleItem],
        samples: [Float],
        sampleRate: Double
    ) -> [SubtitleItem] {
        guard subtitles.count >= 2 else { return subtitles }

        var adjusted = subtitles.sorted { $0.startTime < $1.startTime }
        for index in 0..<(adjusted.count - 1) {
            let current = adjusted[index]
            let next = adjusted[index + 1]
            let gap = next.startTime - current.endTime
            guard gap <= 0.6 else { continue }

            let target = (current.endTime + next.startTime) / 2
            let lower = current.startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
            let upper = next.endTime - LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
            guard let boundary = findQuietBoundaryNear(
                target: target,
                minTime: lower,
                maxTime: upper,
                samples: samples,
                sampleRate: sampleRate,
                searchRadius: 0.2,
                distanceWeight: 0.2,
                windowDuration: LocalPipelineServiceConfig.txtReferenceBoundaryWindowDuration,
                stepDuration: LocalPipelineServiceConfig.txtReferenceBoundaryStepDuration
            ) else {
                continue
            }

            adjusted[index].endTime = max(adjusted[index].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, boundary)
            adjusted[index + 1].startTime = min(boundary, adjusted[index + 1].endTime - LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration)
        }

        return adjusted
    }

    func normalizeReferenceSubtitleOrder(_ subtitles: [SubtitleItem]) -> [SubtitleItem] {
        guard subtitles.count >= 2 else { return subtitles }

        var adjusted = subtitles
        for index in 0..<(adjusted.count - 1) {
            let current = adjusted[index]
            let next = adjusted[index + 1]
            guard current.endTime > next.startTime else { continue }

            let boundary = max(
                current.startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration,
                min(
                    next.endTime - LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration,
                    (current.endTime + next.startTime) / 2
                )
            )

            adjusted[index].endTime = max(adjusted[index].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, boundary)
            adjusted[index + 1].startTime = max(boundary, adjusted[index + 1].startTime)
        }

        return adjusted
    }

    func finalizeReferenceTimeline(_ subtitles: [SubtitleItem]) -> [SubtitleItem] {
        guard !subtitles.isEmpty else { return [] }

        var adjusted = subtitles
        for index in adjusted.indices {
            if index > 0, adjusted[index].startTime < adjusted[index - 1].endTime {
                adjusted[index].startTime = adjusted[index - 1].endTime
            }
            if adjusted[index].endTime <= adjusted[index].startTime {
                adjusted[index].endTime = adjusted[index].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
            }
        }

        for index in 0..<(adjusted.count - 1) {
            if adjusted[index].endTime > adjusted[index + 1].startTime {
                let boundary = max(
                    adjusted[index].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration,
                    min(
                        adjusted[index + 1].endTime - LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration,
                        (adjusted[index].endTime + adjusted[index + 1].startTime) / 2
                    )
                )
                adjusted[index].endTime = max(adjusted[index].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, boundary)
                adjusted[index + 1].startTime = max(boundary, adjusted[index + 1].startTime)
                if adjusted[index + 1].endTime <= adjusted[index + 1].startTime {
                    adjusted[index + 1].endTime = adjusted[index + 1].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
                }
            }
        }

        return adjusted
    }

    func optimizeTXTReferenceSubtitles(
        _ subtitles: [SubtitleItem],
        fallbackSubtitles: [SubtitleItem],
        samples: [Float],
        sampleRate: Double
    ) -> [SubtitleItem] {
        guard !subtitles.isEmpty else { return [] }

        var optimized = subtitles

        for _ in 0..<3 {
            optimized = zip(optimized, fallbackSubtitles).map { subtitle, fallback in
                let adjusted = trimSubtitleToSpeech(
                    subtitle,
                    samples: samples,
                    sampleRate: sampleRate,
                    searchPadding: LocalPipelineServiceConfig.txtReferenceTrimSearchPadding,
                    maxExpansion: 0.18,
                    windowDuration: LocalPipelineServiceConfig.txtReferenceBoundaryWindowDuration
                )
                if isSilentSubtitle(adjusted, samples: samples, sampleRate: sampleRate) {
                    return fallback
                }
                return adjusted
            }
            optimized = preserveMeaningfulTXTReferenceGaps(
                optimized,
                fallbackSubtitles: fallbackSubtitles
            )

            for index in 0..<(optimized.count - 1) {
                let current = optimized[index]
                let next = optimized[index + 1]
                let overlap = max(0, current.endTime - next.startTime)
                let gap = max(0, next.startTime - current.endTime)
                let pairStart = min(current.startTime, next.startTime)
                let pairEnd = max(current.endTime, next.endTime)
                let lower = pairStart + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
                let upper = pairEnd - LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration
                guard upper > lower else { continue }
                guard overlap > 0 || gap <= 0.8 else { continue }

                let target = (current.endTime + next.startTime) / 2
                let searchRadius = min(0.45, max(0.18, overlap + gap + 0.12))
                let boundary = findQuietBoundaryNear(
                    target: target,
                    minTime: lower,
                    maxTime: upper,
                    samples: samples,
                    sampleRate: sampleRate,
                    searchRadius: searchRadius,
                    distanceWeight: 0.15,
                    windowDuration: LocalPipelineServiceConfig.txtReferenceBoundaryWindowDuration,
                    stepDuration: LocalPipelineServiceConfig.txtReferenceBoundaryStepDuration
                ) ?? clamp(target, min: lower, max: upper)

                let currentStart = max(pairStart, current.startTime)
                let nextEnd = min(pairEnd, next.endTime)
                optimized[index].startTime = currentStart
                optimized[index].endTime = max(currentStart + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, boundary)
                optimized[index + 1].startTime = max(boundary, min(next.startTime, nextEnd - LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration))
                optimized[index + 1].endTime = max(optimized[index + 1].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration, nextEnd)
            }

            optimized = preserveMeaningfulTXTReferenceGaps(
                optimized,
                fallbackSubtitles: fallbackSubtitles
            )
            optimized = finalizeReferenceTimeline(normalizeReferenceSubtitleOrder(optimized))
        }

        let gapProtected = preserveMeaningfulTXTReferenceGaps(
            optimized,
            fallbackSubtitles: fallbackSubtitles
        )
        return finalizeReferenceTimeline(normalizeReferenceSubtitleOrder(gapProtected))
    }

    func preserveMeaningfulTXTReferenceGaps(
        _ subtitles: [SubtitleItem],
        fallbackSubtitles: [SubtitleItem]
    ) -> [SubtitleItem] {
        guard subtitles.count >= 2,
              subtitles.count == fallbackSubtitles.count else {
            return subtitles
        }

        var adjusted = subtitles
        for index in 0..<(adjusted.count - 1) {
            let fallbackCurrent = fallbackSubtitles[index]
            let fallbackNext = fallbackSubtitles[index + 1]
            let fallbackGap = fallbackNext.startTime - fallbackCurrent.endTime
            guard fallbackGap >= LocalPipelineServiceConfig.txtReferenceProtectedGapThreshold else { continue }

            adjusted[index].endTime = min(adjusted[index].endTime, fallbackCurrent.endTime)
            adjusted[index + 1].startTime = max(adjusted[index + 1].startTime, fallbackNext.startTime)

            if adjusted[index].endTime <= adjusted[index].startTime {
                adjusted[index].endTime = fallbackCurrent.endTime
            }
            if adjusted[index + 1].endTime <= adjusted[index + 1].startTime {
                adjusted[index + 1].endTime = max(
                    adjusted[index + 1].startTime + LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration,
                    fallbackNext.endTime
                )
            }
        }

        return adjusted
    }

    func mergeTinySubtitles(
        _ subtitles: [SubtitleItem],
        minimumDuration: TimeInterval
    ) -> [SubtitleItem] {
        guard subtitles.count >= 2 else { return subtitles }

        var merged = subtitles.sorted { $0.startTime < $1.startTime }
        var index = 0

        while index < merged.count {
            let duration = merged[index].endTime - merged[index].startTime
            guard duration <= minimumDuration else {
                index += 1
                continue
            }

            if index == 0 {
                merged[1] = SubtitleItem(
                    id: merged[1].id,
                    startTime: merged[index].startTime,
                    endTime: merged[1].endTime,
                    text: joinSubtitleTexts(merged[index].text, merged[1].text)
                )
                merged.remove(at: index)
                continue
            }

            let previousGap = max(0, merged[index].startTime - merged[index - 1].endTime)
            let nextGap = index + 1 < merged.count
                ? max(0, merged[index + 1].startTime - merged[index].endTime)
                : .greatestFiniteMagnitude

            if previousGap <= nextGap || index + 1 >= merged.count {
                merged[index - 1] = SubtitleItem(
                    id: merged[index - 1].id,
                    startTime: merged[index - 1].startTime,
                    endTime: max(merged[index - 1].endTime, merged[index].endTime),
                    text: joinSubtitleTexts(merged[index - 1].text, merged[index].text)
                )
                merged.remove(at: index)
                index = max(0, index - 1)
            } else {
                merged[index + 1] = SubtitleItem(
                    id: merged[index + 1].id,
                    startTime: merged[index].startTime,
                    endTime: merged[index + 1].endTime,
                    text: joinSubtitleTexts(merged[index].text, merged[index + 1].text)
                )
                merged.remove(at: index)
            }
        }

        return merged
    }

    func joinSubtitleTexts(_ lhs: String, _ rhs: String) -> String {
        let trimmedLeft = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeft.isEmpty else { return trimmedRight }
        guard !trimmedRight.isEmpty else { return trimmedLeft }
        return trimmedLeft + "\n" + trimmedRight
    }

    func isSilentSubtitle(_ subtitle: SubtitleItem, samples: [Float], sampleRate: Double) -> Bool {
        let segmentSamples = extractSamples(from: samples, sampleRate: sampleRate, start: subtitle.startTime, end: subtitle.endTime)
        guard !segmentSamples.isEmpty else { return true }

        let peak = segmentSamples.map { abs($0) }.max() ?? 0
        let rms = sqrt(segmentSamples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(segmentSamples.count))
        return peak < 0.02 && rms < 0.004
    }

    func trimSubtitleToSpeech(
        _ subtitle: SubtitleItem,
        samples: [Float],
        sampleRate: Double,
        searchPadding: TimeInterval = 0,
        maxExpansion: TimeInterval = .greatestFiniteMagnitude,
        windowDuration: TimeInterval = 0.01
    ) -> SubtitleItem {
        let totalDuration = Double(samples.count) / sampleRate
        let searchStart = max(0, subtitle.startTime - searchPadding)
        let searchEnd = min(totalDuration, subtitle.endTime + searchPadding)
        let segmentSamples = extractSamples(
            from: samples,
            sampleRate: sampleRate,
            start: searchStart,
            end: searchEnd
        )
        guard !segmentSamples.isEmpty else { return subtitle }

        let windowSize = max(1, Int(sampleRate * windowDuration))
        let leading = firstActiveWindow(in: segmentSamples, windowSize: windowSize)
        let trailing = lastActiveWindow(in: segmentSamples, windowSize: windowSize)
        guard let leading, let trailing, trailing > leading else { return subtitle }

        var trimmed = subtitle
        let paddedStart = max(0, Double(max(0, leading - windowSize / 2)) / sampleRate)
        let paddedEnd = Double(min(segmentSamples.count, trailing + windowSize / 2)) / sampleRate
        let newStart = searchStart + paddedStart
        let newEnd = searchStart + paddedEnd

        if abs(newStart - subtitle.startTime) > 0.04 {
            let boundedStart = max(subtitle.startTime - maxExpansion, newStart)
            trimmed.startTime = min(max(0, boundedStart), subtitle.endTime - 0.12)
        }
        if abs(newEnd - subtitle.endTime) > 0.04 {
            let boundedEnd = min(subtitle.endTime + maxExpansion, newEnd)
            trimmed.endTime = min(searchEnd, max(trimmed.startTime + 0.12, boundedEnd))
        }

        return trimmed
    }

    func firstActiveWindow(in samples: [Float], windowSize: Int) -> Int? {
        guard samples.count >= windowSize else { return samples.firstIndex { abs($0) >= 0.015 } }
        for index in 0...(samples.count - windowSize) {
            let window = samples[index..<(index + windowSize)]
            let peak = window.map { abs($0) }.max() ?? 0
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            if peak >= 0.015 || rms >= 0.003 {
                return index
            }
        }
        return nil
    }

    func lastActiveWindow(in samples: [Float], windowSize: Int) -> Int? {
        guard samples.count >= windowSize else {
            return samples.lastIndex { abs($0) >= 0.015 }
        }
        for index in stride(from: samples.count - windowSize, through: 0, by: -1) {
            let window = samples[index..<(index + windowSize)]
            let peak = window.map { abs($0) }.max() ?? 0
            let rms = sqrt(window.reduce(Float.zero) { $0 + ($1 * $1) } / Float(window.count))
            if peak >= 0.015 || rms >= 0.003 {
                return index + windowSize
            }
        }
        return nil
    }

    func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

}
