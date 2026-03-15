import SwiftUI

struct LivePreviewPanel: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Live Preview", systemImage: "record.circle.fill")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    Task { await viewModel.analyzeAudio() }
                }
                label: {
                    if viewModel.status == .analyzing {
                        HStack(spacing: 8) {
                            SmallGeneratingSpinner()
                            Text("GENERATING...")
                        }
                        .frame(minWidth: 190)
                    } else {
                        Text("AUTO GENERATE")
                            .frame(minWidth: 160)
                    }
                }
                .buttonStyle(StudioPrimaryButton(color: .brandYellow))
                .disabled(viewModel.audioAsset == nil || viewModel.status == .analyzing)
            }
            .padding(16)
            .background(Color.brandPink.opacity(0.28))
            .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)

            ZStack {
                TimelineGridBackground()
                if let analysisProgress = viewModel.analysisProgress, viewModel.status == .analyzing {
                    ProgressPanel(progress: analysisProgress)
                } else if viewModel.status == .aligning {
                    AlignmentProgressPanel(progressText: viewModel.alignmentProgressText)
                } else {
                    Text(viewModel.activeSubtitleText)
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(40)
                        .shadow(color: Color.brandPink, radius: 0, x: 4, y: 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.9))
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .studioPanelChrome()
    }
}

struct ProgressPanel: View {
    let progress: AnalysisProgress

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.brandPink.opacity(0.34))
                    .frame(width: 64, height: 64)
                    .blur(radius: 18)
                LargeGeneratingSpinner()
            }
            Text("ANALYZING...")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .tracking(1.5)
            Text(progress.message)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 16)
                .frame(maxWidth: 360)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 16)
                RoundedRectangle(cornerRadius: 999)
                    .fill(LinearGradient(colors: [.brandPink, .brandViolet], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 320 * max(0, min(progress.displayPercent, 100)) / 100, height: 16)
                    .overlay(alignment: .trailing) {
                        if progress.displayPercent > 5 {
                            Text("\(Int(progress.displayPercent.rounded()))%")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.trailing, 8)
                        }
                    }
            }
            .frame(width: 320)
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(Color.white.opacity(0.25), lineWidth: 2)
            )
        }
    }
}

struct AlignmentProgressPanel: View {
    let progressText: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.brandViolet.opacity(0.22))
                    .frame(width: 52, height: 52)
                    .blur(radius: 14)
                LargeGeneratingSpinner()
            }
            Text("ALIGNING...")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text(progressText)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 24)
        }
    }
}

struct LargeGeneratingSpinner: View {
    @State private var isAnimating = false

    var body: some View {
        SpinnerGlyph(size: 64, lineWidth: 7, tint: .brandPink)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}

struct SmallGeneratingSpinner: View {
    @State private var isAnimating = false

    var body: some View {
        SpinnerGlyph(size: 16, lineWidth: 2.2, tint: .black)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}

struct SpinnerGlyph: View {
    let size: CGFloat
    let lineWidth: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.opacity(Double(index + 1) / 8.0))
                    .frame(width: lineWidth, height: size * 0.28)
                    .offset(y: -(size * 0.22))
                    .rotationEffect(.degrees(Double(index) * 45))
            }
        }
        .frame(width: size, height: size)
    }
}

struct TimelineGridBackground: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let step: CGFloat = 40
                stride(from: 0, through: geometry.size.width, by: step).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
                stride(from: 0, through: geometry.size.height, by: step).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}
