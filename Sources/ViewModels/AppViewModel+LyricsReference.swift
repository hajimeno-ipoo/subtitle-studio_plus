import Foundation

@MainActor
extension AppViewModel {
    func openLyricsReferenceSheet() {
        guard audioAsset != nil else { return }
        isLyricsReferenceSheetPresented = true
    }

    func closeLyricsReferenceSheet() {
        isLyricsReferenceSheetPresented = false
    }

    func requestLyricsReferenceImport() {
        guard audioAsset != nil else { return }
        isLyricsReferenceImporterPresented = true
    }

    func clearLyricsReference() {
        lyricsReferenceText = ""
        lyricsReferenceSourceName = nil
        lyricsReferenceSourceKind = .plainText
        lyricsReferenceEntries = []
    }

    func applyLyricsReferenceText(_ value: String, sourceName: String? = nil) {
        applyLyricsReference(parsedLyricsReference(from: value, sourceName: sourceName))
    }

    func updateLyricsReferenceEditorText(_ value: String) {
        if lyricsReferenceSourceKind == .srt, !lyricsReferenceEntries.isEmpty {
            let parsed = parsedLyricsReference(
                from: value,
                sourceName: lyricsReferenceSourceName
            )
            if parsed.sourceKind == .srt {
                applyLyricsReference(parsed)
            } else {
                applyLyricsReference(
                    preservedSRTReference(
                        from: value,
                        sourceName: lyricsReferenceSourceName,
                        existingEntries: lyricsReferenceEntries
                    )
                )
            }
            return
        }

        applyLyricsReference(
            parsedLyricsReference(
                from: value,
                sourceName: lyricsReferenceSourceName
            )
        )
    }

    func handleImportedLyricsURL(_ url: URL) async {
        do {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess { url.stopAccessingSecurityScopedResource() }
            }

            let contents = try String(contentsOf: url, encoding: .utf8)
            applyLyricsReference(parsedLyricsReference(from: contents, sourceName: url.lastPathComponent))
            isLyricsReferenceSheetPresented = true
        } catch {
            present(error)
        }
    }

    var lyricsReferenceInput: LocalLyricsReferenceInput? {
        let input = LocalLyricsReferenceInput(
            text: lyricsReferenceText,
            sourceName: lyricsReferenceSourceName,
            sourceKind: lyricsReferenceSourceKind,
            entries: lyricsReferenceEntries
        )
        return input.isEmpty ? nil : input
    }

    private func applyLyricsReference(_ input: LocalLyricsReferenceInput) {
        lyricsReferenceText = input.text
        lyricsReferenceSourceName = input.isEmpty ? nil : input.sourceName
        lyricsReferenceSourceKind = input.sourceKind
        lyricsReferenceEntries = input.entries
    }

    private func parsedLyricsReference(from value: String, sourceName: String?) -> LocalLyricsReferenceInput {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parsedSRT = SRTCodec.parseSRT(normalized)
        if !parsedSRT.isEmpty {
            let entries = parsedSRT.enumerated().map { index, item in
                ReferenceLyricEntry(
                    text: item.text,
                    sourceStart: item.startTime,
                    sourceEnd: item.endTime,
                    sourceIndex: index
                )
            }
            return LocalLyricsReferenceInput(
                text: entries.map(\.text).joined(separator: "\n"),
                sourceName: sourceName,
                sourceKind: .srt,
                entries: entries
            )
        }

        return LocalLyricsReferenceInput(
            text: normalized,
            sourceName: sourceName,
            sourceKind: .plainText
        )
    }

    private func preservedSRTReference(
        from value: String,
        sourceName: String?,
        existingEntries: [ReferenceLyricEntry]
    ) -> LocalLyricsReferenceInput {
        let normalizedLines = LocalLyricsReferenceInput(text: value).normalizedLines
        guard !normalizedLines.isEmpty else {
            return LocalLyricsReferenceInput(
                text: "",
                sourceName: sourceName,
                sourceKind: .srt,
                entries: []
            )
        }

        let rebuiltEntries = rebuiltSRTEntries(
            from: normalizedLines,
            existingEntries: existingEntries
        )
        return LocalLyricsReferenceInput(
            text: normalizedLines.joined(separator: "\n"),
            sourceName: sourceName,
            sourceKind: .srt,
            entries: rebuiltEntries
        )
    }

    private func rebuiltSRTEntries(
        from lines: [String],
        existingEntries: [ReferenceLyricEntry]
    ) -> [ReferenceLyricEntry] {
        let timedEntries = existingEntries.filter { $0.sourceStart != nil && $0.sourceEnd != nil }
        guard !timedEntries.isEmpty else {
            return lines.enumerated().map { index, line in
                ReferenceLyricEntry(text: line, sourceStart: nil, sourceEnd: nil, sourceIndex: index)
            }
        }

        let matches = exactLineMatches(
            oldLines: timedEntries.map(\.text),
            newLines: lines
        )
        let matchedByNewIndex = Dictionary(
            uniqueKeysWithValues: matches.map { ($0.newIndex, timedEntries[$0.oldIndex]) }
        )

        var rebuilt = Array<ReferenceLyricEntry?>(repeating: nil, count: lines.count)
        for (newIndex, entry) in matchedByNewIndex {
            rebuilt[newIndex] = ReferenceLyricEntry(
                text: lines[newIndex],
                sourceStart: entry.sourceStart,
                sourceEnd: entry.sourceEnd,
                sourceIndex: newIndex
            )
        }

        let originalStart = timedEntries.first?.sourceStart ?? 0
        let originalEnd = max(
            timedEntries.last?.sourceEnd ?? (originalStart + Double(lines.count) * 0.35),
            originalStart + Double(max(lines.count, 1)) * 0.35
        )

        var index = 0
        while index < lines.count {
            if rebuilt[index] != nil {
                index += 1
                continue
            }

            let blockStart = index
            while index < lines.count, rebuilt[index] == nil {
                index += 1
            }
            let blockEnd = index
            let span = rebuiltSRTSpan(
                for: blockStart..<blockEnd,
                rebuiltEntries: rebuilt,
                originalStart: originalStart,
                originalEnd: originalEnd
            )
            let timings = distributedTimingRanges(
                for: Array(lines[blockStart..<blockEnd]),
                spanStart: span.start,
                spanEnd: span.end,
                totalDuration: originalEnd
            )

            for (offset, timing) in timings.enumerated() {
                let lineIndex = blockStart + offset
                rebuilt[lineIndex] = ReferenceLyricEntry(
                    text: lines[lineIndex],
                    sourceStart: timing.start,
                    sourceEnd: timing.end,
                    sourceIndex: lineIndex
                )
            }
        }

        return rebuilt.compactMap { $0 }
    }

    private func rebuiltSRTSpan(
        for range: Range<Int>,
        rebuiltEntries: [ReferenceLyricEntry?],
        originalStart: TimeInterval,
        originalEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let minimumDuration = Double(range.count) * 0.35
        let previousEntry = rebuiltEntries[..<range.lowerBound].reversed().compactMap { $0 }.first
        let nextEntry = rebuiltEntries.suffix(from: range.upperBound).compactMap { $0 }.first

        if let previousEntry, let nextEntry {
            let start = previousEntry.sourceEnd ?? previousEntry.sourceStart ?? originalStart
            let end = nextEntry.sourceStart ?? nextEntry.sourceEnd ?? originalEnd
            return expandedTimingSpan(
                start: start,
                end: end,
                minimumDuration: minimumDuration,
                lowerBound: originalStart,
                upperBound: originalEnd
            )
        }

        if let previousEntry {
            let previousStart = previousEntry.sourceStart ?? previousEntry.sourceEnd ?? originalStart
            let previousEnd = previousEntry.sourceEnd ?? previousStart
            let baseLength = max(previousEnd - previousStart, minimumDuration)
            return expandedTimingSpan(
                start: previousEnd,
                end: previousEnd + baseLength,
                minimumDuration: minimumDuration,
                lowerBound: originalStart,
                upperBound: originalEnd
            )
        }

        if let nextEntry {
            let nextStart = nextEntry.sourceStart ?? nextEntry.sourceEnd ?? originalEnd
            let nextEnd = nextEntry.sourceEnd ?? nextStart
            let baseLength = max(nextEnd - nextStart, minimumDuration)
            return expandedTimingSpan(
                start: nextStart - baseLength,
                end: nextStart,
                minimumDuration: minimumDuration,
                lowerBound: originalStart,
                upperBound: originalEnd
            )
        }

        return expandedTimingSpan(
            start: originalStart,
            end: originalEnd,
            minimumDuration: minimumDuration,
            lowerBound: originalStart,
            upperBound: originalEnd
        )
    }

    private func expandedTimingSpan(
        start: TimeInterval,
        end: TimeInterval,
        minimumDuration: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        var clampedStart = max(lowerBound, start)
        var clampedEnd = min(upperBound, max(end, clampedStart + 0.35))
        guard clampedEnd - clampedStart >= minimumDuration else {
            let shortfall = minimumDuration - (clampedEnd - clampedStart)
            clampedStart = max(lowerBound, clampedStart - shortfall / 2)
            clampedEnd = min(upperBound, clampedEnd + shortfall / 2)

            if clampedEnd - clampedStart < minimumDuration {
                clampedStart = max(lowerBound, min(clampedStart, upperBound - minimumDuration))
                clampedEnd = min(upperBound, clampedStart + minimumDuration)
            }
            return (clampedStart, max(clampedStart + 0.35, clampedEnd))
        }

        return (clampedStart, clampedEnd)
    }

    private func distributedTimingRanges(
        for lines: [String],
        spanStart: TimeInterval,
        spanEnd: TimeInterval,
        totalDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !lines.isEmpty else { return [] }

        let minimumDuration = 0.35
        let requiredMinimum = Double(lines.count) * minimumDuration
        let upperBound = max(totalDuration, spanStart + requiredMinimum)
        var start = max(0, spanStart)
        var end = min(upperBound, max(spanEnd, start + requiredMinimum))
        if end - start < requiredMinimum {
            start = max(0, min(start, upperBound - requiredMinimum))
            end = min(upperBound, start + requiredMinimum)
        }

        let weights = lines.map { line in
            max(Double(max(line.count, 1)) * 0.22, minimumDuration)
        }
        let totalWeight = max(weights.reduce(0, +), 0.001)
        let available = max(end - start, requiredMinimum)

        var cursor = start
        var timings: [(start: TimeInterval, end: TimeInterval)] = []
        timings.reserveCapacity(lines.count)

        for (index, weight) in weights.enumerated() {
            let remainingMinimum = Double(weights.count - index - 1) * minimumDuration
            let proposedDuration = max(minimumDuration, available * (weight / totalWeight))
            let maxAllowedDuration = max(minimumDuration, (end - cursor) - remainingMinimum)
            let duration = min(proposedDuration, maxAllowedDuration)
            let segmentEnd = index == weights.count - 1 ? end : min(end, cursor + duration)
            timings.append((cursor, max(cursor + minimumDuration, segmentEnd)))
            cursor = max(cursor + minimumDuration, segmentEnd)
        }

        if let last = timings.indices.last {
            timings[last].end = max(timings[last].start + minimumDuration, end)
        }

        return timings.enumerated().map { index, timing in
            let nextStart = index + 1 < timings.count ? timings[index + 1].start : nil
            let safeEnd = nextStart.map { min(timing.end, $0) } ?? timing.end
            return (timing.start, max(timing.start + minimumDuration, safeEnd))
        }
    }

    private func exactLineMatches(
        oldLines: [String],
        newLines: [String]
    ) -> [(oldIndex: Int, newIndex: Int)] {
        guard !oldLines.isEmpty, !newLines.isEmpty else { return [] }

        var dp = Array(
            repeating: Array(repeating: 0, count: newLines.count + 1),
            count: oldLines.count + 1
        )

        for oldIndex in 0..<oldLines.count {
            for newIndex in 0..<newLines.count {
                if oldLines[oldIndex] == newLines[newIndex] {
                    dp[oldIndex + 1][newIndex + 1] = dp[oldIndex][newIndex] + 1
                } else {
                    dp[oldIndex + 1][newIndex + 1] = max(
                        dp[oldIndex][newIndex + 1],
                        dp[oldIndex + 1][newIndex]
                    )
                }
            }
        }

        var matches: [(oldIndex: Int, newIndex: Int)] = []
        var oldIndex = oldLines.count
        var newIndex = newLines.count

        while oldIndex > 0, newIndex > 0 {
            if oldLines[oldIndex - 1] == newLines[newIndex - 1] {
                matches.append((oldIndex - 1, newIndex - 1))
                oldIndex -= 1
                newIndex -= 1
            } else if dp[oldIndex - 1][newIndex] >= dp[oldIndex][newIndex - 1] {
                oldIndex -= 1
            } else {
                newIndex -= 1
            }
        }

        return matches.reversed()
    }
}
