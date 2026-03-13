import SwiftUI

struct WaveformTimelineView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var scrollTarget = 0

    private let rulerHeight: CGFloat = 28
    private let subtitleHeight: CGFloat = 104
    private let waveformHeight: CGFloat = 128
    private let rightPadding: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.black)
            HStack(alignment: .top, spacing: 0) {
                trackHeaders
                timelineScroller
            }
        }
        .studioPanelChrome()
        .onChange(of: viewModel.currentTime) {
            guard viewModel.isPlaying else { return }
            scrollTarget = max(0, Int(viewModel.currentTime.rounded()))
        }
    }

    private var toolbar: some View {
        HStack {
            Button(viewModel.isPlaying ? "Pause" : "Play") {
                viewModel.togglePlayback()
            }
            .buttonStyle(StudioPrimaryButton(color: .brandGreen))
            .disabled(!viewModel.canTogglePlayback)

            VStack(alignment: .leading, spacing: 2) {
                Text("Time")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(Color.brandViolet)
                    .textCase(.uppercase)
                Text("\(SRTCodec.formatDisplayTime(viewModel.currentTime)) / \(SRTCodec.formatDisplayTime(viewModel.audioAsset?.duration ?? 0))")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    viewModel.toggleMute()
                } label: {
                    Image(systemName: viewModel.playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)

                Slider(value: Binding(
                    get: { viewModel.playback.volume },
                    set: { viewModel.setVolume($0) }
                ), in: 0...1)
                .frame(width: 100)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.black, lineWidth: 2))

            HStack(spacing: 10) {
                Button {
                    viewModel.updateZoom(viewModel.viewport.zoom - 20)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)

                Slider(value: Binding(
                    get: { viewModel.viewport.zoom },
                    set: { viewModel.updateZoom($0) }
                ), in: 10...300)
                .frame(width: 120)

                Button {
                    viewModel.updateZoom(viewModel.viewport.zoom + 20)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)

                Text("\(Int(viewModel.viewport.zoom))%")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.black, lineWidth: 2))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.brandPurple.opacity(0.22))
    }

    private var trackHeaders: some View {
        VStack(spacing: 0) {
            Color.white
                .frame(width: 108, height: rulerHeight)
                .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)
            headerBlock(color: .brandOrange, icon: "text.bubble", title: "TEXT", height: subtitleHeight)
            headerBlock(color: .brandPurple, icon: "waveform", title: "AUDIO", height: waveformHeight)
        }
        .frame(width: 108)
        .background(Color.gray.opacity(0.06))
        .overlay(Rectangle().frame(width: 2).foregroundStyle(.black), alignment: .trailing)
    }

    private func headerBlock(color: Color, icon: String, title: String, height: CGFloat) -> some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(color)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.headline).foregroundStyle(.white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black, lineWidth: 1))
            Text(title)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(2)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.16))
        .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)
    }

    private var timelineScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    markerTrack
                    VStack(spacing: 0) {
                        rulerTrack
                        subtitleTrack
                        waveformTrack
                    }
                    playhead
                }
                .frame(width: contentWidth, alignment: .leading)
                .background(Color.white)
            }
            .onChange(of: scrollTarget) {
                withAnimation(.linear(duration: 0.15)) {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
            }
        }
    }

    private var markerTrack: some View {
        HStack(spacing: 0) {
            ForEach(0...max(Int((viewModel.audioAsset?.duration ?? 0).rounded(.up)), 1), id: \.self) { second in
                Color.clear
                    .frame(width: viewModel.viewport.zoom, height: 1)
                    .id(second)
            }
        }
    }

    private var rulerTrack: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white).frame(height: rulerHeight)
            Canvas { context, size in
                let seconds = Int(ceil((viewModel.audioAsset?.duration ?? 0)))
                for second in 0...seconds {
                    let x = CGFloat(second) * viewModel.viewport.zoom
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(Color.black.opacity(0.15)), lineWidth: second % 5 == 0 ? 1.5 : 1)
                    if second < seconds {
                        context.draw(Text(SRTCodec.formatDisplayTime(Double(second))).font(.system(size: 10, weight: .bold, design: .monospaced)), at: CGPoint(x: x + 24, y: 10), anchor: .center)
                    }
                }
            }
        }
        .frame(height: rulerHeight)
        .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)
        .contentShape(Rectangle())
        .gesture(seekGesture)
    }

    private var subtitleTrack: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.brandOrange.opacity(0.08))
            ForEach(viewModel.subtitles) { subtitle in
                SubtitleTimelineBlock(subtitle: subtitle, zoom: viewModel.viewport.zoom, totalDuration: viewModel.audioAsset?.duration ?? 0, trackHeight: subtitleHeight)
            }
        }
        .frame(height: subtitleHeight)
        .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)
        .contentShape(Rectangle())
        .gesture(seekGesture)
    }

    private var waveformTrack: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white)
            Canvas { context, size in
                let samples = viewModel.waveformData.samples
                guard !samples.isEmpty, waveformWidth > 0 else { return }
                let midY = size.height / 2
                let barWidth = waveformWidth / CGFloat(samples.count)

                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * barWidth
                    let height = max(1, CGFloat(sample) * (size.height / 2))
                    let rect = CGRect(x: x, y: midY - height, width: max(barWidth * 0.86, 0.5), height: height * 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Color.brandPink))
                }
            }
            .frame(width: waveformWidth, height: waveformHeight, alignment: .leading)
        }
        .frame(height: waveformHeight)
        .contentShape(Rectangle())
        .gesture(seekGesture)
    }

    private var playhead: some View {
        let x = CGFloat(viewModel.currentTime) * viewModel.viewport.zoom
        return ZStack(alignment: .top) {
            Triangle()
                .fill(Color.brandBlue)
                .frame(width: 18, height: 12)
                .overlay(Triangle().stroke(.black, lineWidth: 1))
            Rectangle()
                .fill(Color.brandBlue)
                .frame(width: 2, height: rulerHeight + subtitleHeight + waveformHeight)
                .offset(y: 12)
        }
        .offset(x: x - 9)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = max(0, min(Double(value.location.x / viewModel.viewport.zoom), viewModel.audioAsset?.duration ?? 0))
                    viewModel.setTime(time)
                }
        )
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = max(0, min(Double(value.location.x / viewModel.viewport.zoom), viewModel.audioAsset?.duration ?? 0))
                viewModel.setTime(time)
            }
    }

    private var contentWidth: CGFloat {
        max(CGFloat(viewModel.audioAsset?.duration ?? 1) * viewModel.viewport.zoom + rightPadding, 600)
    }

    private var waveformWidth: CGFloat {
        max(CGFloat(viewModel.waveformData.duration) * viewModel.viewport.zoom, 0)
    }
}

struct SubtitleTimelineBlock: View {
    @Environment(AppViewModel.self) private var viewModel
    let subtitle: SubtitleItem
    let zoom: CGFloat
    let totalDuration: TimeInterval
    let trackHeight: CGFloat
    @State private var dragStart: SubtitleItem?
    @State private var previewFrame: ClosedRange<TimeInterval>?
    @State private var isHovered = false

    var body: some View {
        let displayStart = previewFrame?.lowerBound ?? subtitle.startTime
        let displayEnd = previewFrame?.upperBound ?? subtitle.endTime
        let width = max(CGFloat(displayEnd - displayStart) * zoom, 12)
        let left = CGFloat(displayStart) * zoom
        let isHighlighted = viewModel.subtitleIsHighlighted(subtitle)

        RoundedRectangle(cornerRadius: 12)
            .fill(isHighlighted ? Color.webHighlightYellow : .white)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black, lineWidth: 2))
            .frame(width: width, height: trackHeight - 16)
            .overlay(alignment: .leading) {
                ResizeHandle(alignment: .leading, isVisible: !viewModel.isLyricsEditMode && (isHovered || previewFrame != nil))
                    .highPriorityGesture(viewModel.isLyricsEditMode ? inactiveDragGesture : resizeGesture(mode: .resizeLeft))
            }
            .overlay(alignment: .trailing) {
                ResizeHandle(alignment: .trailing, isVisible: !viewModel.isLyricsEditMode && (isHovered || previewFrame != nil))
                    .highPriorityGesture(viewModel.isLyricsEditMode ? inactiveDragGesture : resizeGesture(mode: .resizeRight))
            }
            .overlay {
                VStack(spacing: 8) {
                    Text(subtitle.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                    Capsule()
                        .fill(Color.black.opacity(0.08))
                        .frame(width: 42, height: 8)
                }
                .padding(.vertical, 8)
            }
            .help(subtitle.text)
            .position(x: left + (width / 2), y: trackHeight / 2)
            .onHover { hovering in
                isHovered = hovering
            }
            .gesture(viewModel.isLyricsEditMode ? inactiveDragGesture : moveGesture)
            .onTapGesture {
                if viewModel.isLyricsEditMode {
                    viewModel.focusLyricsEditing(id: subtitle.id)
                } else {
                    viewModel.selectSubtitle(id: subtitle.id)
                    viewModel.setTime(subtitle.startTime)
                }
            }
            .disabled(!viewModel.canEditSubtitles)
    }

    private var moveGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                beginDragIfNeeded()
                guard let dragStart else { return }
                let delta = Double((value.location.x - value.startLocation.x) / zoom)
                let duration = dragStart.endTime - dragStart.startTime
                var newStart = max(0, dragStart.startTime + delta)
                var newEnd = newStart + duration
                if newEnd > totalDuration {
                    newEnd = totalDuration
                    newStart = max(0, totalDuration - duration)
                }
                previewFrame = newStart...newEnd
            }
            .onEnded { _ in
                commitDragIfNeeded()
            }
        )
    }

    private func resizeGesture(mode: TimelineDragMode) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                beginDragIfNeeded()
                guard let dragStart else { return }
                let delta = Double((value.location.x - value.startLocation.x) / zoom)
                switch mode {
                case .resizeLeft:
                    let newStart = max(0, min(dragStart.startTime + delta, dragStart.endTime - 0.2))
                    previewFrame = newStart...dragStart.endTime
                case .resizeRight:
                    let newEnd = min(totalDuration, max(dragStart.endTime + delta, dragStart.startTime + 0.2))
                    previewFrame = dragStart.startTime...newEnd
                default:
                    break
                }
            }
            .onEnded { _ in
                commitDragIfNeeded()
            }
        )
    }

    private var inactiveDragGesture: AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: .greatestFiniteMagnitude, coordinateSpace: .global))
    }

    private func beginDragIfNeeded() {
        guard dragStart == nil else { return }
        dragStart = subtitle
        previewFrame = subtitle.startTime...subtitle.endTime
        viewModel.selectSubtitle(id: subtitle.id)
        if viewModel.isPlaying {
            viewModel.togglePlayback()
        }
    }

    private func commitDragIfNeeded() {
        defer {
            dragStart = nil
            previewFrame = nil
        }

        guard let previewFrame else { return }
        guard previewFrame.lowerBound != subtitle.startTime || previewFrame.upperBound != subtitle.endTime else { return }
        viewModel.updateSubtitleFrame(id: subtitle.id, startTime: previewFrame.lowerBound, endTime: previewFrame.upperBound)
    }
}

struct ResizeHandle: View {
    let alignment: Alignment
    let isVisible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.brandBlue.opacity(0.3))
            .frame(width: 10)
            .contentShape(Rectangle())
            .opacity(isVisible ? 1 : 0.001)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
