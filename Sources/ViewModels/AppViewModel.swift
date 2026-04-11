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
    var localPipelineSetupStatus: LocalPipelineSetupStatus = .checking
    var isLocalPipelineSetupBusy = false
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

    var resolveSessionPayload: ResolveSessionPayload?
    var resolveTimelineInfo: ResolveBridgeTimelineInfo?
    private(set) var lastLocalPipelineRunDirectoryURL: URL?
    private(set) var lastLocalPipelineResult: LocalPipelineResult?

    private(set) var undoStack: [[SubtitleItem]] = []
    private(set) var redoStack: [[SubtitleItem]] = []

    private let analysisService: AudioAnalysisService
    private let localPipelineService: any LocalPipelineAnalyzing
    let localPipelineSetupService: LocalPipelineSetupService
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
    var resolveBridgeURL: URL?
    var resolveBridgeMonitorTask: Task<Void, Never>?

    init(
        analysisService: AudioAnalysisService = AudioAnalysisService(),
        localPipelineService: any LocalPipelineAnalyzing = LocalPipelineService(),
        localPipelineSetupService: LocalPipelineSetupService = LocalPipelineSetupService()
    ) {
        self.analysisService = analysisService
        self.localPipelineService = localPipelineService
        self.localPipelineSetupService = localPipelineSetupService
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

    func requestStandardExport() {
        guard canExportStandardSRT else { return }
        isFileExporterPresented = true
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

    func mutateSelectedSubtitle(_ transform: (inout SubtitleItem) -> Void) {
        guard canUseTimelineShortcuts, let selectedSubtitleID, let index = subtitles.firstIndex(where: { $0.id == selectedSubtitleID }) else { return }
        pushUndoState()
        transform(&subtitles[index])
        unsavedChanges.hasUnsavedChanges = true
    }

    func pushUndoState() {
        undoStack.append(subtitles)
        if undoStack.count > 100 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func present(_ error: Error) {
        stopAnalysisDisplayTask()
        analysisProgress = nil
        alignmentProgressText = ""
        dialogState = .init(
            title: "Action failed",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            kind: .error
        )
    }

    func resetLyricsEditState() {
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
