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

                if viewModel.status != .completed {
                    Button(viewModel.status == .analyzing ? "GENERATING..." : "AUTO GENERATE") {
                        Task { await viewModel.analyzeAudio() }
                    }
                    .buttonStyle(StudioPrimaryButton(color: .brandYellow))
                    .disabled(viewModel.audioAsset == nil || viewModel.status == .analyzing)
                }
            }
            .padding(16)
            .background(Color.brandPink.opacity(0.28))
            .overlay(Rectangle().frame(height: 2).foregroundStyle(.black), alignment: .bottom)

            ZStack {
                TimelineGridBackground()
                if viewModel.status == .analyzing || viewModel.status == .aligning {
                    ProgressPanel(progressText: viewModel.progressMessage, progressValue: progressPercentage(from: viewModel.progressMessage))
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
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.black, lineWidth: 2))
        .shadow(color: .black, radius: 0, x: 6, y: 6)
    }

    private func progressPercentage(from text: String) -> Double {
        if let match = text.range(of: #"(\d+)%"#, options: .regularExpression) {
            return Double(text[match].dropLast()) ?? 0
        }
        return 0
    }
}

struct ProgressPanel: View {
    var progressText: String
    var progressValue: Double

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .scaleEffect(1.8)
                .tint(Color.brandPink)
            Text("ANALYZING...")
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text(progressText)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .padding(.horizontal, 24)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 18)
                RoundedRectangle(cornerRadius: 999)
                    .fill(LinearGradient(colors: [.brandPink, .brandViolet], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(progressValue, 100)) * 5, height: 18)
            }
            .frame(width: 500)
            .overlay(RoundedRectangle(cornerRadius: 999).stroke(.white.opacity(0.25), lineWidth: 2))
        }
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
