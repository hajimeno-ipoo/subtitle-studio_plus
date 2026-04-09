import Foundation

@MainActor
extension AppViewModel {
    func startResolveBridgeMonitoring() {
        guard resolveBridgeMonitorTask == nil else { return }
        resolveBridgeMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshResolveBridgeStatus(silent: true)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func requestDaVinciExport() {
        guard canExportForDaVinci else { return }
        Task { await exportForDaVinci() }
    }

    func handleResolveLaunch(_ intent: ResolveLaunchIntent) async {
        do {
            resolveBridgeURL = intent.serverURL ?? resolveBridgeURL
            if intent.sessionURL != nil {
                resolveSessionPayload = try intent.loadSessionPayload()
                if let sessionURL = resolveSessionPayload?.serverURL {
                    resolveBridgeURL = sessionURL
                }
            }
            await refreshResolveBridgeStatus(silent: true)
        } catch {
            present(error)
        }
    }

    private func exportForDaVinci() async {
        guard canExportForDaVinci else { return }

        do {
            let exportAudio = try validatedResolveExportAudioAsset()
            let serverURL = resolveBridgeURL ?? resolveSessionPayload?.serverURL ?? ResolveBridgeClient.defaultServerURL
            let client = ResolveBridgeClient(serverURL: serverURL)
            let request = ResolveDaVinciExportRequest(
                session: resolveSessionPayload,
                timelineInfo: resolveTimelineInfo,
                subtitles: subtitles,
                audioAsset: exportAudio
            )
            let response = try await client.addSubtitles(request)
            try validateResolveExportResponse(response)
            unsavedChanges.hasUnsavedChanges = false

            let body = resolveExportSuccessMessage(response: response)
            dialogState = .init(
                title: "Sent to Resolve",
                message: body,
                kind: .success
            )
        } catch {
            present(error)
        }
    }

    private func validatedResolveExportAudioAsset() throws -> AudioAsset? {
        guard let audioAsset else { return nil }
        guard AudioFileSupport.isResolveExportSupported(url: audioAsset.url) else {
            throw SubtitleStudioError.invalidResolveExportAudioType
        }
        return audioAsset
    }

    private func validateResolveExportResponse(_ response: ResolveBridgeResponse) throws {
        if response.error == true || response.success == false {
            let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Resolve export failed."
            throw SubtitleStudioError.network(message)
        }
    }

    private func resolveExportSuccessMessage(response: ResolveBridgeResponse) -> String {
        let trimmedMessage = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseMessage = (trimmedMessage?.isEmpty == false ? trimmedMessage! : nil)
            ?? fallbackResolveExportSuccessMessage(response: response)

        return baseMessage
    }

    private func fallbackResolveExportSuccessMessage(response: ResolveBridgeResponse) -> String {
        if response.audioSkipped == true {
            return "Subtitles added. Audio already exists at timeline start, so audio placement was skipped."
        }

        if response.audioAdded == true, let trackIndex = response.audioTrackIndex {
            return "Subtitles added. Audio placed on A\(trackIndex)."
        }

        return "Subtitle payload was sent to Resolve."
    }

    private func refreshResolveBridgeStatus(silent: Bool) async {
        let candidates = resolveBridgeCandidates(includeDefault: true)
        guard !candidates.isEmpty else {
            resolveTimelineInfo = nil
            return
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                let info = try await ResolveBridgeClient(serverURL: candidate).getTimelineInfo()
                resolveBridgeURL = candidate
                resolveTimelineInfo = info
                mergeResolveContext(with: info, serverURL: candidate)
                return
            } catch {
                lastError = error
            }
        }

        resolveTimelineInfo = nil
        if !silent, let lastError {
            present(lastError)
        }
    }

    private func resolveBridgeCandidates(includeDefault: Bool = true) -> [URL] {
        var results: [URL] = []
        let candidates = [
            resolveBridgeURL,
            resolveSessionPayload?.serverURL,
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if !results.contains(candidate) {
                results.append(candidate)
            }
        }

        if includeDefault, !results.contains(ResolveBridgeClient.defaultServerURL) {
            results.append(ResolveBridgeClient.defaultServerURL)
        }

        return results
    }

    private func mergeResolveContext(with info: ResolveBridgeTimelineInfo, serverURL: URL) {
        let port = serverURL.port ?? ResolveBridgeClient.defaultPort
        if resolveSessionPayload == nil {
            resolveSessionPayload = ResolveSessionPayload(
                sessionID: info.sessionID ?? "resolve-bridge",
                mode: "launch",
                bridgePort: port,
                audioPath: nil,
                subtitleTrackIndex: 1,
                templateName: "Default Template",
                projectName: info.projectName,
                timelineName: info.name,
                timelineStart: info.timelineStart
            )
            return
        }

        resolveSessionPayload?.bridgePort = port
        resolveSessionPayload?.projectName = info.projectName
        resolveSessionPayload?.timelineName = info.name
        resolveSessionPayload?.timelineStart = info.timelineStart
        resolveSessionPayload?.sessionID = info.sessionID ?? resolveSessionPayload?.sessionID ?? "resolve-bridge"
        if resolveSessionPayload?.templateName?.isEmpty != false {
            resolveSessionPayload?.templateName = "Default Template"
        }
        if resolveSessionPayload?.subtitleTrackIndex == nil {
            resolveSessionPayload?.subtitleTrackIndex = 1
        }
    }
}
