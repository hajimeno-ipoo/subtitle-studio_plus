import Foundation

extension LocalPipelineService {
    func sanitizeAlignedSegments(
        _ segments: [LocalPipelineAlignedSegment],
        orderedDraftSegments: [LocalPipelineDraftSegment]
    ) -> SanitizedAlignmentResult {
        let alignedByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.segmentId, $0) })
        var accepted: [LocalPipelineAlignedSegment] = []
        var rejected: [AlignmentRejectionReason] = []

        for draft in orderedDraftSegments {
            guard let aligned = alignedByID[draft.segmentId], aligned.end > aligned.start else { continue }
            let startDelta = aligned.start - draft.startTime
            let endDelta = aligned.end - draft.endTime

            if draft.referenceSourceKind == .srt {
                let maxShift = LocalPipelineServiceConfig.referenceSRTMaxShift
                guard abs(aligned.start - draft.startTime) <= maxShift,
                      abs(aligned.end - draft.endTime) <= maxShift else {
                    rejected.append(
                        AlignmentRejectionReason(
                            segmentId: draft.segmentId,
                            reason: "srt_shift_guard",
                            startDelta: startDelta,
                            endDelta: endDelta
                        )
                    )
                    continue
                }
            } else if draft.referenceSourceKind == .plainText {
                let searchStart = draft.alignmentSearchStart ?? max(0, draft.startTime - LocalPipelineServiceConfig.aeneasMaxShift)
                let searchEnd = draft.alignmentSearchEnd ?? (draft.endTime + LocalPipelineServiceConfig.aeneasMaxShift)
                guard aligned.start >= searchStart,
                      aligned.end <= searchEnd else {
                    rejected.append(
                        AlignmentRejectionReason(
                            segmentId: draft.segmentId,
                            reason: "txt_search_window_guard",
                            startDelta: startDelta,
                            endDelta: endDelta
                        )
                    )
                    continue
                }
                if isSuspiciousPlainTextAlignment(aligned, draft: draft) {
                    rejected.append(
                        AlignmentRejectionReason(
                            segmentId: draft.segmentId,
                            reason: "txt_clip_edge_guard",
                            startDelta: startDelta,
                            endDelta: endDelta
                        )
                    )
                    continue
                }
            } else {
                let searchStart = draft.alignmentSearchStart ?? max(0, draft.startTime - LocalPipelineServiceConfig.aeneasMaxShift)
                let searchEnd = draft.alignmentSearchEnd ?? (draft.endTime + LocalPipelineServiceConfig.aeneasMaxShift)
                guard aligned.start >= searchStart,
                      aligned.end <= searchEnd else {
                    rejected.append(
                        AlignmentRejectionReason(
                            segmentId: draft.segmentId,
                            reason: "search_window_guard",
                            startDelta: startDelta,
                            endDelta: endDelta
                        )
                    )
                    continue
                }
            }

            if let previousAccepted = accepted.last, aligned.start < previousAccepted.end {
                rejected.append(
                    AlignmentRejectionReason(
                        segmentId: draft.segmentId,
                        reason: draft.referenceSourceKind == .plainText ? "txt_order_guard" : "overlap_with_previous",
                        startDelta: startDelta,
                        endDelta: endDelta
                    )
                )
                continue
            }

            if aligned.end - aligned.start < LocalPipelineServiceConfig.minimumStandaloneSubtitleDuration {
                rejected.append(
                    AlignmentRejectionReason(
                        segmentId: draft.segmentId,
                        reason: "too_short",
                        startDelta: startDelta,
                        endDelta: endDelta
                    )
                )
                continue
            }

            accepted.append(aligned)
        }

        return SanitizedAlignmentResult(accepted: accepted, rejected: rejected)
    }

    func isSuspiciousPlainTextAlignment(
        _ aligned: LocalPipelineAlignedSegment,
        draft: LocalPipelineDraftSegment
    ) -> Bool {
        guard let searchStart = draft.alignmentSearchStart,
              let searchEnd = draft.alignmentSearchEnd else {
            return false
        }

        let searchWindowDuration = searchEnd - searchStart
        let alignedDuration = aligned.end - aligned.start
        let draftDuration = draft.endTime - draft.startTime
        guard searchWindowDuration > 0,
              alignedDuration > 0 else {
            return false
        }

        let consumesSearchWindow =
            abs(aligned.start - searchStart) <= LocalPipelineServiceConfig.txtSuspiciousClipEdgeTolerance
            && abs(aligned.end - searchEnd) <= LocalPipelineServiceConfig.txtSuspiciousClipEdgeTolerance
        let coverageRatio = alignedDuration / searchWindowDuration
        let hasLargeExcessWindow = searchWindowDuration - draftDuration >= LocalPipelineServiceConfig.txtSuspiciousClipExcessDuration

        return consumesSearchWindow
            && coverageRatio >= LocalPipelineServiceConfig.txtSuspiciousClipCoverageRatio
            && hasLargeExcessWindow
    }

    func runAlignment(
        runId: String,
        sourceFileName: String,
        draftSegments: [LocalPipelineDraftSegment],
        normalizedSamples: [Float],
        sampleRate: Double,
        layout: RunDirectoryLayout,
        settings: LocalPipelineSettings,
        allowsReferenceFallback: Bool,
        resolvedPaths: ResolvedPaths,
        logger: RunLogger,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> [LocalPipelineAlignedSegment] {
        guard !draftSegments.isEmpty else { return [] }

        let inputSegments = try buildAlignmentInputSegments(
            from: draftSegments,
            normalizedSamples: normalizedSamples,
            sampleRate: sampleRate,
            layout: layout
        )

        let inputManifest = AlignmentInputManifest(
            runId: runId,
            sourceFileName: sourceFileName,
            language: settings.language,
            segments: inputSegments
        )
        let manifestURL = layout.alignmentInputDirectoryURL.appendingPathComponent("segments.json")
        let outputJSONURL = layout.alignmentInputDirectoryURL.appendingPathComponent("segment_alignment.json")
        try writeJSON(inputManifest, to: manifestURL)
        let tracker = AlignmentProgressTracker(totalBlocks: inputSegments.count, progress: progress)
        let request = ExternalProcessRequest(
            executablePath: resolvedPaths.pythonExecutableURL.path,
            arguments: buildAeneasArguments(
                scriptURL: resolvedPaths.aeneasScriptURL,
                inputAudioURL: layout.inputDirectoryURL.appendingPathComponent("normalized.wav"),
                segmentsJSONURL: manifestURL,
                language: settings.language,
                outputJSONURL: outputJSONURL
            ),
            workingDirectory: layout.rootURL,
            environment: buildProcessEnvironment(extraExecutableURLs: [resolvedPaths.pythonExecutableURL]),
            timeout: max(240, Double(inputSegments.count) * LocalPipelineServiceConfig.alignmentTimeoutPerBlock),
            onStderrChunk: { data in
                await tracker.consume(data)
            }
        )
        let command = renderCommandLine(executablePath: request.executablePath, arguments: request.arguments)
        let result: ExternalProcessResult
        do {
            result = try await processRunner.run(request)
        } catch let error as ExternalProcessRunnerError {
            switch error {
            case let .timedOut(_, timeout, stdout, stderr):
                try appendTimedOutProcessOutput(
                    stdout: stdout,
                    stderr: stderr,
                    to: layout.aeneasStderrURL,
                    header: "==== aeneas ====\n"
                )
                if allowsReferenceFallback {
                    try logger.log(
                        runId: runId,
                        stage: LocalPipelinePhase.aligning.rawValue,
                        level: .warn,
                        message: "aeneas timed out after \(timeout)s; using draft timing fallback",
                        engineType: .localPipeline,
                        command: command,
                        stderrPath: layout.aeneasStderrURL
                    )
                    return []
                }
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.aligning.rawValue,
                    level: .error,
                    message: "aeneas timed out after \(timeout)s",
                    engineType: .localPipeline,
                    command: command,
                    stderrPath: layout.aeneasStderrURL
                )
                throw LocalPipelineError.alignmentFailed(readStdErr(layout.aeneasStderrURL) ?? "aeneas timed out after \(timeout)s")
            default:
                throw error
            }
        }

        try appendStderr(result.stderr, to: layout.aeneasStderrURL, header: "==== aeneas ====\n")

        guard result.exitCode == 0 else {
            if allowsReferenceFallback {
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.aligning.rawValue,
                    level: .warn,
                    message: "aeneas failed; using draft timing fallback",
                    engineType: .localPipeline,
                    command: command,
                    exitCode: result.exitCode,
                    stderrPath: layout.aeneasStderrURL
                )
                return []
            }
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .error,
                message: "aeneas failed",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
            throw LocalPipelineError.alignmentFailed(readStdErr(layout.aeneasStderrURL) ?? "aeneas exited with code \(result.exitCode)")
        }

        let outputData = try readJSONData(
            fallbackURL: outputJSONURL,
            stdout: result.stdout,
            failureMessage: "aeneas did not produce JSON output"
        )
        let output = try decodeAlignmentOutput(from: outputData)
        guard !output.segments.isEmpty else {
            if allowsReferenceFallback {
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.aligning.rawValue,
                    level: .warn,
                    message: "aeneas produced no aligned blocks; using reference timing fallback",
                    engineType: .localPipeline,
                    command: command,
                    exitCode: result.exitCode,
                    stderrPath: layout.aeneasStderrURL
                )
                return []
            }
            let details = buildAlignmentFailureMessage(stderrURL: layout.aeneasStderrURL)
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .error,
                message: "aeneas produced no aligned blocks",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
            throw LocalPipelineError.alignmentFailed(details)
        }
        try logger.log(
            runId: runId,
            stage: LocalPipelinePhase.aligning.rawValue,
            level: .info,
            message: "aeneas aligned blocks",
            engineType: .localPipeline,
            command: command,
            exitCode: result.exitCode,
            stderrPath: layout.aeneasStderrURL
        )
        let sanitization = sanitizeAlignedSegments(
            output.segments,
            orderedDraftSegments: draftSegments
        )
        let filteredSegments = sanitization.accepted

        if filteredSegments.isEmpty, allowsReferenceFallback {
            if !sanitization.rejected.isEmpty {
                let details = sanitization.rejected.prefix(8).map { rejection in
                    "\(rejection.segmentId):\(rejection.reason)(startDelta=\(String(format: "%.3f", rejection.startDelta)), endDelta=\(String(format: "%.3f", rejection.endDelta)))"
                }.joined(separator: ", ")
                try logger.log(
                    runId: runId,
                    stage: LocalPipelinePhase.aligning.rawValue,
                    level: .warn,
                    message: "txt alignment rejected all blocks: \(details)",
                    engineType: .localPipeline,
                    command: command,
                    exitCode: result.exitCode,
                    stderrPath: layout.aeneasStderrURL
                )
            }
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .warn,
                message: "aeneas aligned blocks fell outside reference guard window; using fallback timing",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
            return []
        }

        if filteredSegments.count != output.segments.count {
            let details = sanitization.rejected.prefix(8).map { rejection in
                "\(rejection.segmentId):\(rejection.reason)(startDelta=\(String(format: "%.3f", rejection.startDelta)), endDelta=\(String(format: "%.3f", rejection.endDelta)))"
            }.joined(separator: ", ")
            try logger.log(
                runId: runId,
                stage: LocalPipelinePhase.aligning.rawValue,
                level: .warn,
                message: "discarded \(output.segments.count - filteredSegments.count) misaligned block(s): \(details)",
                engineType: .localPipeline,
                command: command,
                exitCode: result.exitCode,
                stderrPath: layout.aeneasStderrURL
            )
        }

        return filteredSegments
    }

    func buildAlignmentInputSegments(
        from draftSegments: [LocalPipelineDraftSegment],
        normalizedSamples: [Float],
        sampleRate: Double,
        layout: RunDirectoryLayout
    ) throws -> [AlignmentInputSegment] {
        let groups = makeAlignmentGroups(from: draftSegments)
        return try groups.map { group in
            let first = group[0]
            let last = group[group.count - 1]
            let clipStart = max(0, group.compactMap(\.alignmentSearchStart).min() ?? (first.startTime - LocalPipelineServiceConfig.alignmentPadding))
            let clipEnd = max(clipStart + 0.2, group.compactMap(\.alignmentSearchEnd).max() ?? (last.endTime + LocalPipelineServiceConfig.alignmentPadding))
            let clipURL = layout.alignmentInputDirectoryURL.appendingPathComponent("\(first.segmentId).wav")
            let clipSamples = extractSamples(
                from: normalizedSamples,
                sampleRate: sampleRate,
                start: clipStart,
                end: clipEnd
            )
            try writePCM16WAV(samples: clipSamples, sampleRate: sampleRate, to: clipURL)
            return AlignmentInputSegment(
                segmentId: first.segmentId,
                startTime: first.startTime,
                endTime: last.endTime,
                text: group.map(\.text).joined(separator: "\n"),
                audioPath: clipURL.path,
                clipStartTime: clipStart,
                lineSegmentIDs: group.count > 1 ? group.map(\.segmentId) : nil,
                lineTexts: group.count > 1 ? group.map(\.text) : nil,
                lineStartTimes: group.count > 1 ? group.map(\.startTime) : nil,
                lineEndTimes: group.count > 1 ? group.map(\.endTime) : nil,
                lineSearchStartTimes: group.count > 1 ? group.map { $0.alignmentSearchStart ?? $0.startTime } : nil,
                lineSearchEndTimes: group.count > 1 ? group.map { $0.alignmentSearchEnd ?? $0.endTime } : nil
            )
        }
    }

    func makeAlignmentGroups(from draftSegments: [LocalPipelineDraftSegment]) -> [[LocalPipelineDraftSegment]] {
        guard !draftSegments.isEmpty else { return [] }

        var groups: [[LocalPipelineDraftSegment]] = []
        var current: [LocalPipelineDraftSegment] = []

        func shouldBreak(current: [LocalPipelineDraftSegment], next: LocalPipelineDraftSegment) -> Bool {
            guard let last = current.last else { return false }
            if next.referenceSourceKind == .plainText, last.referenceSourceKind == .plainText {
                if current.count >= LocalPipelineServiceConfig.txtGroupedAlignmentMaxLines { return true }
                if next.startTime - last.endTime > LocalPipelineServiceConfig.txtGroupedAlignmentMaxGap { return true }
                if next.endTime - current[0].startTime > LocalPipelineServiceConfig.txtGroupedAlignmentMaxSpan { return true }
                return false
            }
            guard next.referenceSourceKind == nil, last.referenceSourceKind == nil else { return true }
            if current.count >= LocalPipelineServiceConfig.nonReferenceGroupedAlignmentMaxLines { return true }
            if next.startTime - last.endTime > LocalPipelineServiceConfig.nonReferenceGroupedAlignmentMaxGap { return true }
            if next.endTime - current[0].startTime > LocalPipelineServiceConfig.nonReferenceGroupedAlignmentMaxSpan { return true }
            return false
        }

        for segment in draftSegments {
            if current.isEmpty {
                current = [segment]
            } else if shouldBreak(current: current, next: segment) {
                groups.append(current)
                current = [segment]
            } else {
                current.append(segment)
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    func decodeAlignmentOutput(from data: Data) throws -> LocalPipelineSegmentAlignmentOutput {
        do {
            return try JSONDecoder().decode(LocalPipelineSegmentAlignmentOutput.self, from: data)
        } catch {
            throw LocalPipelineError.invalidJSON("Invalid aeneas JSON: \(error.localizedDescription)")
        }
    }

    func readJSONData(fallbackURL: URL, stdout: Data, failureMessage: String) throws -> Data {
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return try Data(contentsOf: fallbackURL)
        }
        guard !stdout.isEmpty else {
            throw LocalPipelineError.invalidJSON(failureMessage)
        }
        return stdout
    }

    func cleanupSuccessfulRunArtifacts(
        layout: RunDirectoryLayout,
        preserveAlignmentArtifacts: Bool = false
    ) throws {
        let fileManager = FileManager.default
        var removableDirectories = [
            layout.inputDirectoryURL,
            layout.chunksDirectoryURL
        ]
        if !preserveAlignmentArtifacts {
            removableDirectories.append(layout.alignmentInputDirectoryURL)
        }

        for directoryURL in removableDirectories where fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
    }

    func buildAlignmentFailureMessage(stderrURL: URL) -> String {
        guard let stderrText = readStdErr(stderrURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !stderrText.isEmpty else {
            return "aeneas did not align any subtitle blocks."
        }

        if stderrText.contains("[WARN]") || stderrText.contains("[ERROR]") {
            return stderrText
        }

        return "aeneas did not align any subtitle blocks."
    }

    func appendStderr(_ data: Data, to url: URL, header: String) throws {
        try appendText(header, to: url)
        if !data.isEmpty {
            try appendData(data, to: url)
            try appendText("\n", to: url)
        }
    }

    func appendTimedOutProcessOutput(
        stdout: Data,
        stderr: Data,
        to url: URL,
        header: String
    ) throws {
        if !stdout.isEmpty {
            try appendStderr(stdout, to: url, header: header + "[stdout]\n")
        }
        if !stderr.isEmpty {
            try appendStderr(stderr, to: url, header: header + "[stderr]\n")
        }
    }

    func appendText(_ value: String, to url: URL) throws {
        guard let data = value.data(using: .utf8) else { return }
        try appendData(data, to: url)
    }

    func appendData(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    func readStdErr(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func renderCommandLine(executablePath: String, arguments: [String]) -> String {
        ([executablePath] + arguments).map { component in
            if component.contains(where: \.isWhitespace) {
                return "\"\(component)\""
            }
            return component
        }
        .joined(separator: " ")
    }
}
