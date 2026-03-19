import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppViewModel {
    static let nudgeStep = 0.05

    var audioAsset: AudioAsset?
    var subtitles: [SubtitleItem] = []
    var status: ProcessingStatus = .idle
    var analysisProgress: AnalysisProgress?
    var alignmentProgressText = ""
    var currentTime: TimeInterval = 0
    var dialogState: AppDialogState?
    var pendingImportIntent: AudioImportIntent?
    var selectedSubtitleID: UUID?
    var editingSubtitleID: UUID?
    var selectionBeforeLyricsEdit: UUID?
    var lastEditedSubtitleID: UUID?
    var viewport = TimelineViewport()
    var settings = SettingsStore()
    var isDropTargeted = false
    var isSettingsPresented = false
    var isFileImporterPresented = false
    var isFileExporterPresented = false
    var isLyricsEditMode = false
    var unsavedChanges = UnsavedChangesState()

    private(set) var resolveSessionPayload: ResolveSessionPayload?
    private(set) var resolveTimelineInfo: ResolveBridgeTimelineInfo?

    private(set) var undoStack: [[SubtitleItem]] = []
    private(set) var redoStack: [[SubtitleItem]] = []

    private let analysisService = AudioAnalysisService()
    @ObservationTracked
    var alignmentService: SubtitleAlignmentService {
        let config = AlignmentConfig(
            searchWindowPad: 2.0,
            rmsWindowSize: settings.autoAlignRMSWindowSize,
            thresholdRatio: settings.autoAlignThresholdRatio,
            minVolumeAbsolute: 0.002,
            padStart: 0.15,
            padEnd: 0.25,
            maxSnapDistance: 1.0,
            minGapFill: settings.autoAlignMinGapFill,
            useAdaptiveThreshold: settings.autoAlignUseAdaptiveThreshold
        )
        return SubtitleAlignmentService(config: config)
    }
    let playback = AudioPlaybackController()
    private let waveformService = WaveformService()
    private var analysisDisplayTask: Task<Void, Never>?
    private var resolveBridgeURL: URL?
    private var resolveBridgeMonitorTask: Task<Void, Never>?

    init() {
        playback.onTimeChange = { [weak self] time in
            self?.currentTime = time
        }
        #if DEBUG
        loadDebugSeedIfNeeded()
        #endif
    }

    var hasAudio: Bool { audioAsset != nil }
    var isPlaying: Bool { playback.isPlaying }
    var hasUnsavedChanges: Bool { unsavedChanges.hasUnsavedChanges }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isBusy: Bool { status == .analyzing || status == .aligning }
    var canEditSubtitles: Bool { !isBusy && !subtitles.isEmpty }
    var isTextInputActive: Bool { NSApp.keyWindow?.firstResponder is NSTextView }
    var canUseTimelineShortcuts: Bool { canEditSubtitles && selectedSubtitleID != nil && !isLyricsEditMode && !isTextInputActive }
    var canTogglePlayback: Bool { hasAudio && !isLyricsEditMode && !isTextInputActive }
    var canDeleteSelectedSubtitle: Bool { canEditSubtitles && selectedSubtitleID != nil && !isLyricsEditMode && !isTextInputActive }
    var isResolveSessionActive: Bool { resolveTimelineInfo != nil }
    var canExportStandardSRT: Bool { !subtitles.isEmpty }
    var canExportForDaVinci: Bool { isResolveSessionActive && !subtitles.isEmpty }
    var activeSubtitleText: String {
        subtitles.first(where: { currentTime >= $0.startTime && currentTime <= $0.endTime })?.text ?? ""
    }

    var highlightedSubtitleID: UUID? {
        selectedSubtitleID ?? subtitles.first(where: subtitleIsPlayingNow)?.id
    }

    func subtitleIsPlayingNow(_ subtitle: SubtitleItem) -> Bool {
        currentTime >= subtitle.startTime && currentTime <= subtitle.endTime
    }

    func subtitleIsHighlighted(_ subtitle: SubtitleItem) -> Bool {
        highlightedSubtitleID == subtitle.id
    }

    func requestOpenAudio() {
        isFileImporterPresented = true
    }

    func startResolveBridgeMonitoring() {
        guard resolveBridgeMonitorTask == nil else { return }
        resolveBridgeMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshResolveBridgeStatus(silent: true)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func requestStandardExport() {
        guard canExportStandardSRT else { return }
        isFileExporterPresented = true
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

    func handleImportedURL(_ url: URL) async {
        if hasUnsavedChanges && audioAsset != nil {
            pendingImportIntent = .replace(url)
            dialogState = .init(title: "Replace current audio?", message: "Current subtitle edits will be lost. Continue?", kind: .unsavedChanges)
            return
        }
        await loadAudio(url)
    }

    func confirmPendingImport() async {
        guard case let .replace(url)? = pendingImportIntent else { return }
        pendingImportIntent = nil
        dialogState = nil
        await loadAudio(url)
    }

    func cancelPendingImport() {
        pendingImportIntent = nil
        dialogState = nil
    }

    func loadAudio(_ url: URL) async {
        do {
            guard AudioFileSupport.isSupported(url: url) else { throw SubtitleStudioError.invalidAudioType }
            let resource = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let fileSize = Int64(resource.fileSize ?? 0)
            guard fileSize <= 100 * 1024 * 1024 else { throw SubtitleStudioError.fileTooLarge }

            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess { url.stopAccessingSecurityScopedResource() }
            }

            let duration = try waveformService.audioDuration(url: url)
            try playback.load(url: url)
            audioAsset = AudioAsset(url: url, fileName: url.lastPathComponent, duration: duration, fileSize: fileSize, contentType: resource.contentType)
            subtitles = []
            resetInternalState()
        } catch {
            present(error)
        }
    }

    func requestReset() {
        if hasUnsavedChanges {
            dialogState = .init(
                title: "Close current project?",
                message: "You have unsaved changes. Are you sure you want to return to the start screen?",
                kind: .confirmReset
            )
        } else {
            resetProject()
        }
    }

    func resetProject() {
        audioAsset = nil
        subtitles = []
        resetInternalState()
        dialogState = nil
        playback.stop()
    }

    private func resetInternalState() {
        resetLyricsEditState()
        status = .idle
        analysisProgress = nil
        alignmentProgressText = ""
        currentTime = 0
        unsavedChanges.hasUnsavedChanges = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func loadSubtitles(from url: URL) {
        do {
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gotAccess { url.stopAccessingSecurityScopedResource() }
            }

            let contents = try String(contentsOf: url, encoding: .utf8)
            let parsed = SRTCodec.parseSRT(contents)
            guard !parsed.isEmpty else {
                throw SubtitleStudioError.invalidSRTResponse
            }

            subtitles = parsed
            resetLyricsEditState()
            status = .completed
            currentTime = 0
            unsavedChanges.hasUnsavedChanges = false
            undoStack.removeAll()
            redoStack.removeAll()
        } catch {
            present(error)
        }
    }

    func togglePlayback() {
        guard canTogglePlayback else { return }
        if !playback.isPlaying {
            selectedSubtitleID = nil
        }
        playback.togglePlayback()
    }

    func setTime(_ value: TimeInterval) {
        playback.seek(to: value)
        currentTime = playback.currentTime
    }

    func setVolume(_ value: Double) {
        playback.setVolume(value)
        viewport.volume = playback.volume
        viewport.isMuted = playback.isMuted
    }

    func toggleMute() {
        playback.toggleMute()
        viewport.volume = playback.volume
        viewport.isMuted = playback.isMuted
    }

    func updateZoom(_ value: CGFloat) {
        viewport.zoom = max(10, min(value, 200))
    }

    func analyzeAudio() async {
        guard let audioAsset else { return }
        await settings.loadIfNeeded()
        let apiKey = settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            present(SubtitleStudioError.missingAPIKey)
            isSettingsPresented = true
            return
        }

        status = .analyzing
        alignmentProgressText = ""
        analysisProgress = .init(
            phase: .loadingAudio,
            message: "Preparing...",
            actualPercent: 0,
            displayPercent: 0
        )
        dialogState = nil

        do {
            let result = try await analysisService.analyze(fileURL: audioAsset.url, apiKey: apiKey) { [weak self] progress in
                await MainActor.run {
                    self?.applyAnalysisProgress(progress)
                }
            }
            pushUndoState()
            subtitles = result
            resetLyricsEditState()
            await completeAnalysisProgress()
            status = .completed
            unsavedChanges.hasUnsavedChanges = true
        } catch {
            stopAnalysisDisplayTask()
            status = .error
            analysisProgress = nil
            present(error)
        }
    }

    func autoAlign() async {
        guard let audioAsset, !subtitles.isEmpty else { return }
        status = .aligning
        alignmentProgressText = "Analyzing waveform..."
        analysisProgress = nil
        do {
            let result = try await alignmentService.align(audioURL: audioAsset.url, subtitles: subtitles) { [weak self] message in
                await MainActor.run {
                    self?.alignmentProgressText = message
                }
            }
            pushUndoState()
            subtitles = result
            status = .completed
            alignmentProgressText = ""
            unsavedChanges.hasUnsavedChanges = true
        } catch {
            status = .error
            alignmentProgressText = ""
            present(error)
        }
    }

    func updateSubtitleText(id: UUID, text: String, recordUndo: Bool = true) {
        guard let index = subtitles.firstIndex(where: { $0.id == id }) else { return }
        guard subtitles[index].text != text else { return }
        if recordUndo {
            pushUndoState()
        }
        subtitles[index].text = text
        unsavedChanges.hasUnsavedChanges = true
    }

    func toggleLyricsEditMode() {
        if isLyricsEditMode {
            exitLyricsEditMode()
            return
        } else {
            guard canEditSubtitles else { return }
            enterLyricsEditMode()
        }
    }

    func beginLyricsEditing(id: UUID) {
        guard isLyricsEditMode, subtitles.contains(where: { $0.id == id }) else { return }
        selectedSubtitleID = id
        editingSubtitleID = id
    }

    func focusLyricsEditing(id: UUID) {
        beginLyricsEditing(id: id)
    }

    func markLyricsEdited(id: UUID) {
        guard isLyricsEditMode, subtitles.contains(where: { $0.id == id }) else { return }
        lastEditedSubtitleID = id
    }

    func deleteSelectedSubtitle() {
        guard canDeleteSelectedSubtitle, let selectedSubtitleID else { return }
        deleteSubtitle(id: selectedSubtitleID)
    }

    func deleteSubtitle(id: UUID) {
        guard let index = subtitles.firstIndex(where: { $0.id == id }) else { return }
        pushUndoState()
        
        // リップル削除のための移動量を計算 (削除する字幕の長さ + 余白0.1秒)
        let removedItem = subtitles[index]
        let shiftAmount = (removedItem.endTime - removedItem.startTime) + 0.1
        
        subtitles.remove(at: index)
        
        // リップル削除: 削除地点以降のすべての字幕を前にシフト
        for i in index..<subtitles.count {
            subtitles[i].startTime = max(0, subtitles[i].startTime - shiftAmount)
            subtitles[i].endTime = max(0.1, subtitles[i].endTime - shiftAmount)
        }
        
        if isLyricsEditMode {
            if editingSubtitleID == id {
                editingSubtitleID = nil
            }
            if lastEditedSubtitleID == id {
                lastEditedSubtitleID = nil
            }
        } else {
            selectedSubtitleID = subtitles.indices.contains(index) ? subtitles[index].id : subtitles.last?.id
        }
        if selectionBeforeLyricsEdit == id {
            selectionBeforeLyricsEdit = nil
        }
        unsavedChanges.hasUnsavedChanges = true
    }

    func insertSubtitle(after id: UUID?) {
        pushUndoState()
        
        let newItemDuration: TimeInterval = 2.0
        let gap: TimeInterval = 0.1
        let shiftAmount = newItemDuration + gap
        
        let startTime: TimeInterval
        let insertIndex: Int
        
        if let id = id, let index = subtitles.firstIndex(where: { $0.id == id }) {
            // 指定された字幕の直後に挿入
            startTime = subtitles[index].endTime + gap
            insertIndex = index + 1
        } else {
            // IDがnilの場合はリストの先頭に挿入
            startTime = subtitles.first?.startTime.advanced(by: -shiftAmount) ?? currentTime
            insertIndex = 0
        }
        
        // リップル編集: 挿入地点以降のすべての字幕をシフト
        // (重複を避けるため、後ろから順番に処理する必要はないが、ロジックとして明確にする)
        for i in insertIndex..<subtitles.count {
            subtitles[i].startTime += shiftAmount
            subtitles[i].endTime += shiftAmount
        }
        
        let newItem = SubtitleItem(startTime: max(0, startTime), endTime: max(newItemDuration, startTime + newItemDuration), text: "")
        subtitles.insert(newItem, at: insertIndex)
        
        selectedSubtitleID = newItem.id
        if isLyricsEditMode {
            editingSubtitleID = newItem.id
        }
        
        unsavedChanges.hasUnsavedChanges = true
    }

    func addSubtitle() {
        // 既存の機能との互換性のため維持。基本的には insertSubtitle(after: subtitles.last?.id) と同等。
        insertSubtitle(after: subtitles.last?.id)
    }

    func selectSubtitle(id: UUID?) {
        selectedSubtitleID = id
    }

    func replaceSubtitles(_ updated: [SubtitleItem], markDirty: Bool = true) {
        subtitles = updated
        if markDirty {
            unsavedChanges.hasUnsavedChanges = true
        }
    }

    func nudgeSelectedSubtitle(delta: TimeInterval) {
        mutateSelectedSubtitle { subtitle in
            let duration = subtitle.endTime - subtitle.startTime
            subtitle.startTime = max(0, subtitle.startTime + delta)
            subtitle.endTime = subtitle.startTime + duration
            if let total = audioAsset?.duration, subtitle.endTime > total {
                subtitle.endTime = total
                subtitle.startTime = max(0, total - duration)
            }
        }
    }

    func resizeSelectedSubtitleStart(delta: TimeInterval) {
        mutateSelectedSubtitle { subtitle in
            subtitle.startTime = max(0, min(subtitle.startTime + delta, subtitle.endTime - 0.2))
        }
    }

    func resizeSelectedSubtitleEnd(delta: TimeInterval) {
        mutateSelectedSubtitle { subtitle in
            let limit = audioAsset?.duration ?? .greatestFiniteMagnitude
            subtitle.endTime = min(limit, max(subtitle.endTime + delta, subtitle.startTime + 0.2))
        }
    }

    func updateSubtitleFrame(id: UUID, startTime: TimeInterval, endTime: TimeInterval) {
        guard let index = subtitles.firstIndex(where: { $0.id == id }) else { return }
        subtitles[index].startTime = max(0, startTime)
        subtitles[index].endTime = max(startTime + 0.2, endTime)
        unsavedChanges.hasUnsavedChanges = true
    }

    func exportDocument() -> SRTDocument {
        SRTDocument(text: SRTCodec.generateSRT(from: subtitles))
    }

    func handleExportCompletion(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            unsavedChanges.hasUnsavedChanges = false
        case .failure(let error):
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
            unsavedChanges.hasUnsavedChanges = false

            let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body: String
            if let message, !message.isEmpty {
                body = message
            } else {
                body = resolveExportSuccessMessage(response: response)
            }
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

    private func resolveExportSuccessMessage(response: ResolveBridgeResponse) -> String {
        if response.audioSkipped == true {
            return "Subtitles added. Audio already exists at timeline start, so audio placement was skipped."
        }

        if response.audioAdded == true, let trackIndex = response.audioTrackIndex {
            return "Subtitles added. Audio placed on A\(trackIndex)."
        }

        return "Subtitle payload was sent to Resolve."
    }

    private func refreshResolveBridgeStatus(silent: Bool) async {
        let candidates = resolveBridgeCandidates()
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

    private func resolveBridgeCandidates() -> [URL] {
        var results: [URL] = []
        let candidates = [
            resolveBridgeURL,
            resolveSessionPayload?.serverURL,
            ResolveBridgeClient.defaultServerURL,
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if !results.contains(candidate) {
                results.append(candidate)
            }
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

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(subtitles)
        subtitles = previous
        reconcileEditingTargets()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(subtitles)
        subtitles = next
        reconcileEditingTargets()
    }

    private func mutateSelectedSubtitle(_ transform: (inout SubtitleItem) -> Void) {
        guard canUseTimelineShortcuts, let selectedSubtitleID, let index = subtitles.firstIndex(where: { $0.id == selectedSubtitleID }) else { return }
        pushUndoState()
        transform(&subtitles[index])
        unsavedChanges.hasUnsavedChanges = true
    }

    private func pushUndoState() {
        undoStack.append(subtitles)
        if undoStack.count > 100 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func present(_ error: Error) {
        stopAnalysisDisplayTask()
        analysisProgress = nil
        alignmentProgressText = ""
        dialogState = .init(
            title: "Action failed",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            kind: .error
        )
    }

    private func enterLyricsEditMode() {
        if playback.isPlaying {
            playback.pause()
        }
        isLyricsEditMode = true
        selectionBeforeLyricsEdit = selectedSubtitleID
        selectedSubtitleID = nil
        editingSubtitleID = nil
        lastEditedSubtitleID = nil
    }

    private func exitLyricsEditMode() {
        isLyricsEditMode = false
        editingSubtitleID = nil
        selectedSubtitleID = lastEditedSubtitleID ?? selectionBeforeLyricsEdit
        selectionBeforeLyricsEdit = nil
        lastEditedSubtitleID = nil
    }

    private func resetLyricsEditState() {
        selectedSubtitleID = nil
        editingSubtitleID = nil
        selectionBeforeLyricsEdit = nil
        lastEditedSubtitleID = nil
        isLyricsEditMode = false
    }

    #if DEBUG
    private func loadDebugSeedIfNeeded() {
        let processInfo = ProcessInfo.processInfo
        let shouldSeed = processInfo.environment["SUBTITLE_STUDIO_UI_SEED"] == "1"
            || processInfo.arguments.contains("--ui-seed")
        guard shouldSeed else { return }
        guard audioAsset == nil, subtitles.isEmpty else { return }

        audioAsset = AudioAsset(
            url: URL(fileURLWithPath: "/tmp/subtitle-studio-ui-seed.wav"),
            fileName: "debug-seed.wav",
            duration: 18,
            fileSize: 0,
            contentType: nil
        )
        subtitles = [
            SubtitleItem(startTime: 1, endTime: 4, text: "debug one"),
            SubtitleItem(startTime: 5, endTime: 8, text: "debug two"),
            SubtitleItem(startTime: 9, endTime: 12, text: "debug three"),
        ]
        status = .idle
        currentTime = 0
        unsavedChanges.hasUnsavedChanges = false
        undoStack.removeAll()
        redoStack.removeAll()
    }
    #endif

    private func reconcileEditingTargets() {
        guard isLyricsEditMode else { return }
        if let editingSubtitleID, !subtitles.contains(where: { $0.id == editingSubtitleID }) {
            self.editingSubtitleID = nil
        }
        if let lastEditedSubtitleID, !subtitles.contains(where: { $0.id == lastEditedSubtitleID }) {
            self.lastEditedSubtitleID = nil
        }
        if let selectionBeforeLyricsEdit, !subtitles.contains(where: { $0.id == selectionBeforeLyricsEdit }) {
            self.selectionBeforeLyricsEdit = nil
        }
    }

    private func applyAnalysisProgress(_ incoming: AnalysisProgress) {
        let actualPercent = max(incoming.actualPercent, analysisProgress?.actualPercent ?? 0)
        let displayCeiling = incoming.phase == .completed ? 100 : max(actualPercent, incoming.displayPercent)
        let currentDisplay = analysisProgress?.displayPercent ?? 0

        analysisProgress = AnalysisProgress(
            phase: incoming.phase,
            message: incoming.message,
            actualPercent: actualPercent,
            displayPercent: max(currentDisplay, actualPercent),
            currentChunk: incoming.currentChunk,
            totalChunks: incoming.totalChunks
        )

        startAnalysisDisplayTask(maxDisplay: displayCeiling)
    }

    private func startAnalysisDisplayTask(maxDisplay: Double) {
        analysisDisplayTask?.cancel()
        analysisDisplayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                guard var progress = self.analysisProgress else { return }
                let ceiling = progress.phase == .completed ? 100 : max(progress.actualPercent, maxDisplay)
                if progress.displayPercent >= ceiling {
                    return
                }
                progress.displayPercent = min(ceiling, progress.displayPercent + 0.8)
                self.analysisProgress = progress
            }
        }
    }

    private func completeAnalysisProgress() async {
        analysisDisplayTask?.cancel()
        guard var progress = analysisProgress else { return }
        progress.phase = .completed
        while progress.displayPercent < 100 {
            progress.displayPercent = min(100, progress.displayPercent + 4)
            analysisProgress = progress
            try? await Task.sleep(for: .milliseconds(45))
        }
        progress.actualPercent = 100
        progress.displayPercent = 100
        progress.message = "全工程完了！"
        analysisProgress = progress
        try? await Task.sleep(for: .milliseconds(700))
        analysisProgress = nil
        analysisDisplayTask = nil
    }

    private func stopAnalysisDisplayTask() {
        analysisDisplayTask?.cancel()
        analysisDisplayTask = nil
    }
}
