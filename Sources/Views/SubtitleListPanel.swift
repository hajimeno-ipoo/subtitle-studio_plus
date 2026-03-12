import SwiftUI

struct SubtitleListPanel: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("SUBTITLES", systemImage: "text.bubble")
                    .font(.system(size: 14, weight: .black, design: .rounded))

                Spacer()

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
                            ForEach(viewModel.subtitles) { subtitle in
                                SubtitleRow(subtitle: subtitle, isActive: viewModel.currentTime >= subtitle.startTime && viewModel.currentTime <= subtitle.endTime)
                                    .id(subtitle.id)
                            }
                        }
                    }
                    .padding(14)
                }
                .onChange(of: viewModel.currentTime) {
                    if let active = viewModel.subtitles.first(where: { viewModel.currentTime >= $0.startTime && viewModel.currentTime <= $0.endTime }) {
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
    let subtitle: SubtitleItem
    let isActive: Bool
    @State private var draftText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("\(SRTCodec.formatDisplayTime(subtitle.startTime)) → \(SRTCodec.formatDisplayTime(subtitle.endTime))")
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isActive ? Color.brandYellow : Color.black.opacity(0.05))
                .clipShape(Capsule())

                Spacer()

                Button {
                    viewModel.deleteSubtitle(id: subtitle.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!viewModel.canEditSubtitles)
            }

            TextEditor(text: $draftText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(height: editorHeight)
                .focused($focused)
                .disabled(!viewModel.canEditSubtitles)
                .onAppear {
                    draftText = subtitle.text
                }
                .onChange(of: subtitle.text) {
                    if !focused {
                        draftText = subtitle.text
                    }
                }
                .onChange(of: focused) {
                    viewModel.setEditingText(focused)
                    if !focused, draftText != subtitle.text {
                        viewModel.updateSubtitleText(id: subtitle.id, text: draftText)
                    }
                }
                .onTapGesture {
                    viewModel.selectSubtitle(id: subtitle.id)
                }
        }
        .padding(12)
        .background(isActive ? Color.brandYellow.opacity(0.5) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .studioOffsetShadow(cornerRadius: 14, x: 4, y: 4, enabled: isActive)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isActive ? .black : Color.black.opacity(0.16), lineWidth: isActive ? 2 : 1))
        .onTapGesture {
            viewModel.selectSubtitle(id: subtitle.id)
            viewModel.setTime(subtitle.startTime)
        }
    }

    private var editorHeight: CGFloat {
        let newlineCount = max(1, draftText.split(separator: "\n", omittingEmptySubsequences: false).count)
        let wrappedLineCount = max(1, Int(ceil(Double(max(draftText.count, 1)) / 30.0)))
        let visibleLines = min(3, max(newlineCount, wrappedLineCount))
        return switch visibleLines {
        case 1: 34
        case 2: 54
        default: 72
        }
    }
}
