import Foundation

@MainActor
extension AppViewModel {
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

        let removedItem = subtitles[index]
        let shiftAmount = (removedItem.endTime - removedItem.startTime) + 0.1

        subtitles.remove(at: index)

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
            startTime = subtitles[index].endTime + gap
            insertIndex = index + 1
        } else {
            startTime = subtitles.first?.startTime.advanced(by: -shiftAmount) ?? currentTime
            insertIndex = 0
        }

        for i in insertIndex..<subtitles.count {
            subtitles[i].startTime += shiftAmount
            subtitles[i].endTime += shiftAmount
        }

        let newItem = SubtitleItem(
            startTime: max(0, startTime),
            endTime: max(newItemDuration, startTime + newItemDuration),
            text: ""
        )
        subtitles.insert(newItem, at: insertIndex)

        selectedSubtitleID = newItem.id
        if isLyricsEditMode {
            editingSubtitleID = newItem.id
        }

        unsavedChanges.hasUnsavedChanges = true
    }

    func addSubtitle() {
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
        let sanitizedStart = max(0, startTime)
        let sanitizedEnd = max(sanitizedStart + 0.2, endTime)
        guard subtitles[index].startTime != sanitizedStart || subtitles[index].endTime != sanitizedEnd else { return }
        pushUndoState()
        subtitles[index].startTime = sanitizedStart
        subtitles[index].endTime = sanitizedEnd
        unsavedChanges.hasUnsavedChanges = true
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
}
