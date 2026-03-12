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
    var viewport = TimelineViewport()
    var waveformData = WaveformData(samples: [], duration: 0)
    var settings = SettingsStore()
    var isDropTargeted = false
    var isSettingsPresented = false
    var isFileImporterPresented = false
    var isFileExporterPresented = false
    var isEditingText = false
    var unsavedChanges = UnsavedChangesState()

    private(set) var undoStack: [[SubtitleItem]] = []
    private(set) var redoStack: [[SubtitleItem]] = []

    private let analysisService = AudioAnalysisService()
    private let alignmentService = SubtitleAlignmentService()
    let playback = AudioPlaybackController()
    private let waveformService = WaveformService()
    private var analysisDisplayTask: Task<Void, Never>?

    init() {
        playback.onTimeChange = { [weak self] time in
            self?.currentTime = time
        }
    }

    var hasAudio: Bool { audioAsset != nil }
    var isPlaying: Bool { playback.isPlaying }
    var hasUnsavedChanges: Bool { unsavedChanges.hasUnsavedChanges }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isBusy: Bool { status == .analyzing || status == .aligning }
    var canEditSubtitles: Bool { !isBusy && !subtitles.isEmpty }
    var canUseTimelineShortcuts: Bool { canEditSubtitles && selectedSubtitleID != nil && !isEditingText }
    var activeSubtitleText: String {
        subtitles.first(where: { currentTime >= $0.startTime && currentTime <= $0.endTime })?.text ?? ""
    }

    func requestOpenAudio() {
        isFileImporterPresented = true
    }

    func requestExport() {
        guard !subtitles.isEmpty else { return }
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

            let waveform = try waveformService.loadWaveform(url: url)
            try playback.load(url: url)
            audioAsset = AudioAsset(url: url, fileName: url.lastPathComponent, duration: waveform.duration, fileSize: fileSize, contentType: resource.contentType)
            waveformData = waveform
            subtitles = []
            selectedSubtitleID = nil
            status = .idle
            analysisProgress = nil
            alignmentProgressText = ""
            currentTime = 0
            dialogState = nil
            unsavedChanges.hasUnsavedChanges = false
            undoStack.removeAll()
            redoStack.removeAll()
        } catch {
            present(error)
        }
    }

    func togglePlayback() {
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
        viewport.zoom = max(10, min(value, 300))
    }

    func analyzeAudio() async {
        guard let audioAsset else { return }
        settings.loadIfNeeded()
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
            await completeAnalysisProgress()
            status = .completed
            unsavedChanges.hasUnsavedChanges = true
            selectedSubtitleID = subtitles.first?.id
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

    func updateSubtitleText(id: UUID, text: String) {
        guard let index = subtitles.firstIndex(where: { $0.id == id }) else { return }
        pushUndoState()
        subtitles[index].text = text
        unsavedChanges.hasUnsavedChanges = true
    }

    func deleteSelectedSubtitle() {
        guard let selectedSubtitleID else { return }
        deleteSubtitle(id: selectedSubtitleID)
    }

    func deleteSubtitle(id: UUID) {
        guard let index = subtitles.firstIndex(where: { $0.id == id }) else { return }
        pushUndoState()
        subtitles.remove(at: index)
        selectedSubtitleID = subtitles.indices.contains(index) ? subtitles[index].id : subtitles.last?.id
        unsavedChanges.hasUnsavedChanges = true
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

    func setEditingText(_ isEditing: Bool) {
        isEditingText = isEditing
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(subtitles)
        subtitles = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(subtitles)
        subtitles = next
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

    private func applyAnalysisProgress(_ incoming: AnalysisProgress) {
        let actualPercent = max(incoming.actualPercent, analysisProgress?.actualPercent ?? 0)
        let displayCeiling = incoming.phase == .completed ? 100 : max(actualPercent, incoming.displayPercent)
        let currentDisplay = analysisProgress?.displayPercent ?? 0

        analysisProgress = AnalysisProgress(
            phase: incoming.phase,
            message: incoming.message,
            actualPercent: actualPercent,
            displayPercent: max(currentDisplay, actualPercent),
            partialTranscript: incoming.partialTranscript,
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
        progress.message = "All steps completed!"
        analysisProgress = progress
        try? await Task.sleep(for: .milliseconds(220))
        analysisProgress = nil
        analysisDisplayTask = nil
    }

    private func stopAnalysisDisplayTask() {
        analysisDisplayTask?.cancel()
        analysisDisplayTask = nil
    }
}
