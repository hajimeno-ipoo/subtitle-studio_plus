import SwiftUI

struct SubtitleListPanel: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var bindableViewModel = viewModel

        VStack(spacing: 0) {
            HStack {
                Label("SUBTITLES", systemImage: "text.bubble")
                    .font(.system(size: 14, weight: .black, design: .rounded))

                Spacer()

                Button(viewModel.isLyricsEditMode ? "DONE" : "EDIT LYRICS") {
                    viewModel.toggleLyricsEditMode()
                }
                .buttonStyle(StudioSecondaryButton())
                .disabled(!viewModel.canEditSubtitles && !viewModel.isLyricsEditMode)

                Button(viewModel.status == .aligning ? "ALIGNING..." : "AUTO-ALIGN") {
                    Task { await viewModel.autoAlign() }
                }
                .buttonStyle(StudioPrimaryButton(color: .brandViolet))
                .disabled(viewModel.subtitles.isEmpty || viewModel.status == .aligning)

                Text("\(viewModel.subtitles.count)")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.black, lineWidth: 1))
            }
            .padding(14)
            .background(Color.brandCyan.opacity(0.3))
            .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.subtitles.isEmpty {
                            VStack(spacing: 6) {
                                Text("NO SUBTITLES")
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                Text("Click AUTO GENERATE to start.")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            ForEach(Array(bindableViewModel.subtitles.indices), id: \.self) { index in
                                let subtitle = bindableViewModel.subtitles[index]
                                SubtitleRow(
                                    subtitleNumber: index + 1,
                                    subtitle: $bindableViewModel.subtitles[index],
                                    isHighlighted: viewModel.subtitleIsHighlighted(subtitle),
                                    isPlayingNow: viewModel.subtitleIsPlayingNow(subtitle)
                                )
                                    .id(subtitle.id)
                            }
                        }
                    }
                    .padding(14)
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
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isHighlighted ? Color.webHighlightChip : Color.black.opacity(0.05))
                .clipShape(Capsule())

                Spacer()

                Text("#\(subtitleNumber)")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)

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

    private var editableCardContent: some View {
        cardChrome {
            VStack(alignment: .leading, spacing: 8) {
                cardInnerContent
                TextEditor(text: $subtitle.text)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
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
                    .font(.system(size: 14, weight: .medium, design: .rounded))
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
        .padding(12)
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
        let wrappedLineCount = max(1, Int(ceil(Double(max(text.count, 1)) / 30.0)))
        let visibleLines = max(newlineCount, wrappedLineCount)
        return 34 + (CGFloat(visibleLines - 1) * 20)
    }
}
