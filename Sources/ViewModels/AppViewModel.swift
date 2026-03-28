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
    var localPipelineProgress: LocalPipelineProgress?
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
    var isLyricsReferenceSheetPresented = false
    var isLyricsReferenceImporterPresented = false
    var isLyricsEditMode = false
    var unsavedChanges = UnsavedChangesState()
    var lyricsReferenceText = ""
    var lyricsReferenceSourceName: String?
    var lyricsReferenceSourceKind: LyricsReferenceSourceKind = .plainText
    var lyricsReferenceEntries: [ReferenceLyricEntry] = []

    private(set) var resolveSessionPayload: ResolveSessionPayload?
    private(set) var resolveTimelineInfo: ResolveBridgeTimelineInfo?
    private(set) var lastLocalPipelineRunDirectoryURL: URL?
    private(set) var lastLocalPipelineResult: LocalPipelineResult?

    private(set) var undoStack: [[SubtitleItem]] = []
    private(set) var redoStack: [[SubtitleItem]] = []

    private let analysisService: AudioAnalysisService
    private let localPipelineService: any LocalPipelineAnalyzing
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

    init(
        analysisService: AudioAnalysisService = AudioAnalysisService(),
        localPipelineService: any LocalPipelineAnalyzing = LocalPipelineService()
    ) {
        self.analysisService = analysisService
        self.localPipelineService = localPipelineService
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
    var hasLyricsReference: Bool { !(lyricsReferenceInput?.isEmpty ?? true) }
    var lyricsReferenceSummary: String? {
        guard let lyricsReferenceInput, !lyricsReferenceInput.isEmpty else { return nil }
        return lyricsReferenceInput.sourceName ?? "貼り付けた歌詞"
    }
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
            settings.applyRecommendedLocalBaseModelIfNeeded(for: url.lastPathComponent)
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
        clearLyricsReference()
        isLyricsReferenceSheetPresented = false
        isLyricsReferenceImporterPresented = false
        status = .idle
        analysisProgress = nil
        localPipelineProgress = nil
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

        status = .analyzing
        localPipelineProgress = nil
        alignmentProgressText = ""
        analysisProgress = .init(
            phase: .loadingAudio,
            message: "Preparing...",
            actualPercent: 0,
            displayPercent: 0
        )
        dialogState = nil

        switch settings.selectedSRTGenerationEngine {
        case .gemini:
            await analyzeWithGemini(fileURL: audioAsset.url)
        case .localPipeline:
            await analyzeWithLocalPipeline(fileURL: audioAsset.url)
        }
    }

    private func analyzeWithGemini(fileURL: URL) async {
        let apiKey = settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            status = .idle
            analysisProgress = nil
            present(SubtitleStudioError.missingAPIKey)
            isSettingsPresented = true
            return
        }

        do {
            let result = try await analysisService.analyze(fileURL: fileURL, apiKey: apiKey) { [weak self] progress in
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

    private func analyzeWithLocalPipeline(fileURL: URL) async {
        do {
            let result = try await localPipelineService.analyze(
                fileURL: fileURL,
                settings: settings.localPipelineSettings,
                lyricsReference: lyricsReferenceInput
            ) { [weak self] progress in
                await MainActor.run {
                    self?.localPipelineProgress = progress
                    self?.applyLocalPipelineProgress(progress)
                }
            }

            pushUndoState()
            subtitles = result.subtitles
            resetLyricsEditState()
            lastLocalPipelineRunDirectoryURL = result.runDirectoryURL
            lastLocalPipelineResult = result
            await completeAnalysisProgress()
            status = .completed
            unsavedChanges.hasUnsavedChanges = true
        } catch {
            stopAnalysisDisplayTask()
            status = .error
            analysisProgress = nil
            localPipelineProgress = nil
            present(error)
        }
    }

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
        let candidates = resolveBridgeCandidates(includeDefault: !silent)
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
        guard clampedEnd - clampedStart < minimumDuration else {
            return (clampedStart, clampedEnd)
        }

        let shortfall = minimumDuration - (clampedEnd - clampedStart)
        clampedStart = max(lowerBound, clampedStart - shortfall / 2)
        clampedEnd = min(upperBound, clampedEnd + shortfall / 2)

        if clampedEnd - clampedStart < minimumDuration {
            clampedStart = max(lowerBound, min(clampedStart, upperBound - minimumDuration))
            clampedEnd = min(upperBound, clampedStart + minimumDuration)
        }

        return (clampedStart, max(clampedStart + 0.35, clampedEnd))
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

    private func applyLocalPipelineProgress(_ incoming: LocalPipelineProgress) {
        let mappedPhase = mapLocalPhaseToAnalysisPhase(incoming.phase)
        let actualPercent = max(incoming.displayPercent, analysisProgress?.actualPercent ?? 0)
        let currentDisplay = analysisProgress?.displayPercent ?? 0
        let message = incoming.totalChunks > 0
            ? "\(incoming.message) (\(incoming.currentChunk)/\(incoming.totalChunks))"
            : incoming.message

        analysisProgress = AnalysisProgress(
            phase: mappedPhase,
            message: message,
            actualPercent: actualPercent,
            displayPercent: max(currentDisplay, actualPercent),
            currentChunk: incoming.currentChunk,
            totalChunks: incoming.totalChunks
        )

        startAnalysisDisplayTask(maxDisplay: actualPercent)
    }

    private func mapLocalPhaseToAnalysisPhase(_ phase: LocalPipelinePhase) -> AnalysisPhase {
        switch phase {
        case .validating:
            .loadingAudio
        case .preparing:
            .optimizingAudio
        case .chunking:
            .chunking
        case .baseTranscribing:
            .requestingChunk
        case .aligning, .correcting, .assembling:
            .parsingChunk
        case .writingOutputs:
            .mergingChunks
        }
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
        localPipelineProgress = nil
        analysisDisplayTask = nil
    }

    private func stopAnalysisDisplayTask() {
        analysisDisplayTask?.cancel()
        analysisDisplayTask = nil
    }
}
