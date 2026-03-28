import SwiftUI
import UniformTypeIdentifiers

struct SubtitleListPanel: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var bindableViewModel = viewModel

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 14, weight: .medium))
                    Text("SUBTITLES")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .lineLimit(1)
                .fixedSize()

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        viewModel.openLyricsReferenceSheet()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.hasLyricsReference ? "text.badge.checkmark" : "text.badge.plus")
                                .font(.system(size: 12, weight: .bold))
                            Text(viewModel.hasLyricsReference ? "LYRICS READY" : "IMPORT LYRICS")
                        }
                    }
                    .buttonStyle(StudioSecondaryButton())
                    .fixedSize(horizontal: true, vertical: false)

                    Button(viewModel.isLyricsEditMode ? "DONE" : "EDIT LYRICS") {
                        viewModel.toggleLyricsEditMode()
                    }
                    .buttonStyle(StudioSecondaryButton())
                    .disabled(!viewModel.canEditSubtitles && !viewModel.isLyricsEditMode)
                    .fixedSize(horizontal: true, vertical: false)

                    if viewModel.isLyricsEditMode && viewModel.canUndo {
                        Button {
                            viewModel.undo()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .font(.system(size: 14, weight: .bold))
                                Text("UNDO")
                            }
                        }
                        .buttonStyle(StudioSecondaryButton())
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    Button {
                        Task { await viewModel.autoAlign() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars.inverse")
                                .font(.system(size: 12, weight: .bold))
                            Text(viewModel.status == .aligning ? "ALIGNING..." : "AUTO-ALIGN")
                        }
                    }
                    .buttonStyle(StudioPrimaryButton(color: .brandViolet, textColor: .white))
                    .disabled(viewModel.subtitles.isEmpty || viewModel.status == .aligning)
                    .fixedSize(horizontal: true, vertical: false)

                    Text("\(viewModel.subtitles.count)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .frame(minWidth: 32)
                        .frame(height: 36)
                        .padding(.horizontal, 8)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black, lineWidth: 2))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.brandCyan.opacity(0.3))
            .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) { // 字幕間の余白を調整
                        if viewModel.subtitles.isEmpty {
                            VStack(spacing: 8) {
                                Text("NO SUBTITLES")
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                Text("Click AUTO GENERATE to start.")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                if let summary = viewModel.lyricsReferenceSummary {
                                    Text("Lyrics ready: \(summary)")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.brandViolet)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            if viewModel.isLyricsEditMode {
                                InlineAddButton(after: nil)
                            }
                            
                            ForEach($bindableViewModel.subtitles) { $subtitle in
                                let index = bindableViewModel.subtitles.firstIndex(where: { $0.id == subtitle.id }) ?? 0
                                SubtitleRow(
                                    subtitleNumber: index + 1,
                                    subtitle: $subtitle,
                                    isHighlighted: viewModel.subtitleIsHighlighted(subtitle),
                                    isPlayingNow: viewModel.subtitleIsPlayingNow(subtitle)
                                )
                                .id(subtitle.id)
                                
                                if viewModel.isLyricsEditMode {
                                    InlineAddButton(after: subtitle.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.editingSubtitleID) {
                    guard viewModel.isLyricsEditMode, let editingSubtitleID = viewModel.editingSubtitleID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(editingSubtitleID, anchor: .center)
                    }
                }
                .onChange(of: viewModel.currentTime) {
                    if !viewModel.isLyricsEditMode,
                       let active = viewModel.subtitles.first(where: { viewModel.currentTime >= $0.startTime && viewModel.currentTime <= $0.endTime }) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(active.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .studioPanelChrome()
    }
}

struct LyricsReferenceSheet: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var bindableViewModel = viewModel

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REFERENCE LYRICS")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                Text("必要な時だけ歌詞を貼り付けるか、TXT / SRT を読み込みます。通常は空のままで構いません。")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                if let summary = viewModel.lyricsReferenceSummary {
                    Text("現在の参照元: \(summary)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.brandViolet)
                }
            }

            TextEditor(
                text: Binding(
                    get: { bindableViewModel.lyricsReferenceText },
                    set: { viewModel.updateLyricsReferenceEditorText($0) }
                )
            )
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .padding(8)
                .frame(minHeight: 260)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black, lineWidth: 2))

            HStack(spacing: 8) {
                Button("LOAD TXT / SRT") {
                    viewModel.requestLyricsReferenceImport()
                }
                .buttonStyle(StudioSecondaryButton())

                Button("CLEAR") {
                    viewModel.clearLyricsReference()
                }
                .buttonStyle(StudioSecondaryButton())
                .disabled(!viewModel.hasLyricsReference)

                Spacer()

                Button("DONE") {
                    viewModel.closeLyricsReferenceSheet()
                }
                .buttonStyle(StudioPrimaryButton(color: .brandViolet, textColor: .white))
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .background(Color.backgroundYellow)
        .fileImporter(
            isPresented: bind(\.isLyricsReferenceImporterPresented),
            allowedContentTypes: supportedLyricsTypes,
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await viewModel.handleImportedLyricsURL(url) }
            }
        }
    }

    private var supportedLyricsTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let srt = UTType(filenameExtension: "srt") {
            types.append(srt)
        }
        return types
    }

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppViewModel, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { viewModel[keyPath: keyPath] = $0 }
        )
    }
}

struct InlineAddButton: View {
    @Environment(AppViewModel.self) private var viewModel
    let after: UUID?
    @State private var isHovered = false
    
    var body: some View {
        Button {
            viewModel.insertSubtitle(after: after)
        } label: {
            ZStack {
                Rectangle()
                    .fill(isHovered ? Color.brandYellow.opacity(0.3) : Color.white.opacity(0.001))
                    .frame(height: 16)
                
                HStack {
                    Rectangle()
                        .fill(isHovered ? Color.brandYellow : Color.brandYellow.opacity(0.3))
                        .frame(height: 1)
                    
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isHovered ? Color.brandYellow : Color.brandYellow.opacity(0.5))
                        .background(Circle().fill(.black).frame(width: 8, height: 8))
                    
                    Rectangle()
                        .fill(isHovered ? Color.brandYellow : Color.brandYellow.opacity(0.3))
                        .frame(height: 1)
                }
                .opacity(isHovered ? 1.0 : 0.0)
            }
            .contentShape(Rectangle()) // 透明な領域でもヒットテストを有効にする
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct SubtitleRow: View {
    @Environment(AppViewModel.self) private var viewModel
    let subtitleNumber: Int
    @Binding var subtitle: SubtitleItem
    let isHighlighted: Bool
    let isPlayingNow: Bool

    var body: some View {
        if viewModel.isLyricsEditMode {
            editableCardContent
        } else {
            selectableCardContent
        }
    }

    private var cardInnerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("\(SRTCodec.formatDisplayTime(subtitle.startTime)) → \(SRTCodec.formatDisplayTime(subtitle.endTime))")
                }
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isHighlighted ? Color.webHighlightChip : Color.black.opacity(0.05))
                .clipShape(Capsule())

                Spacer()

                Text("#\(subtitleNumber)")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)

                if viewModel.isLyricsEditMode {
                    Button {
                        viewModel.deleteSubtitle(id: subtitle.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!viewModel.canEditSubtitles)
                }
            }
        }
    }

    private var editableCardContent: some View {
        cardChrome {
            VStack(alignment: .leading, spacing: 8) {
                cardInnerContent
                TextEditor(text: $subtitle.text)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .onChange(of: subtitle.text) {
                        viewModel.beginLyricsEditing(id: subtitle.id)
                        viewModel.markLyricsEdited(id: subtitle.id)
                        viewModel.unsavedChanges.hasUnsavedChanges = true
                    }
                    .frame(height: editorHeight)
                    .disabled(!viewModel.canEditSubtitles)
            }
        }
    }

    private var selectableCardContent: some View {
        cardChrome {
            VStack(alignment: .leading, spacing: 8) {
                cardInnerContent
                Text(subtitle.text)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: editorHeight, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            viewModel.selectSubtitle(id: subtitle.id)
            viewModel.setTime(subtitle.startTime)
        }
    }

    private func cardChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
        .padding(16)
        .background(isHighlighted ? Color.webHighlightYellow : .white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .studioOffsetShadow(cornerRadius: 14, x: 4, y: 4, enabled: isHighlighted)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isHighlighted ? .black : Color.black.opacity(0.16), lineWidth: isHighlighted ? 2 : 1)
                .allowsHitTesting(false)
        )
    }

    private var editorHeight: CGFloat {
        let text = subtitle.text
        let newlineCount = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let wrappedLineCount = max(1, Int(ceil(Double(max(text.count, 1)) / 25.0)))
        let visibleLines = max(newlineCount, wrappedLineCount)
        return 34 + (CGFloat(visibleLines - 1) * 20)
    }
}
