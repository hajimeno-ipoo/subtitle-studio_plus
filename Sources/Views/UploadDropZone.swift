import SwiftUI
import UniformTypeIdentifiers

struct UploadDropZone: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var isHovered = false

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Button {
                    viewModel.requestOpenAudio()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(containerBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 28)
                                    .strokeBorder(containerBorder, style: StrokeStyle(lineWidth: 4, dash: [14]))
                            )
                            .frame(maxWidth: 860, minHeight: 320)

                        VStack(spacing: 18) {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(iconBackground)
                                .stroke(.black, lineWidth: 2)
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 42, weight: .black))
                                        .foregroundStyle(iconForeground)
                                )
                                .studioOffsetShadow(
                                    cornerRadius: 24,
                                    x: iconShadowOffset,
                                    y: iconShadowOffset
                                )
                                .scaleEffect(iconScale)
                                .rotationEffect(.degrees(iconRotation))
                                .animation(.easeOut(duration: 0.18), value: visualState)

                            Text(titleText)
                                .font(.system(size: 38, weight: .black, design: .rounded))
                                .foregroundStyle(titleColor)
                                .animation(.easeOut(duration: 0.18), value: visualState)
                            Text("MP3, WAV (Max 100MB)")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(chipBackground)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(chipBorder, lineWidth: 2))
                                .foregroundStyle(Color.gray.opacity(0.88))
                                .animation(.easeOut(duration: 0.18), value: visualState)
                        }
                    }
                }
                .buttonStyle(UploadDropZoneButtonStyle())
                .contentShape(RoundedRectangle(cornerRadius: 28))
                .onHover { hovering in
                    isHovered = hovering
                }
                .accessibilityLabel("Upload audio")
                .accessibilityHint("Open a file picker to choose an audio file")
            }
            .onDrop(of: [.fileURL], isTargeted: bind(\.isDropTargeted)) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in
                            await viewModel.handleImportedURL(url)
                        }
                    }
                }
                return true
            }
            Spacer()
        }
    }

    private var visualState: UploadDropZoneVisualState {
        if viewModel.isDropTargeted {
            return .dragging
        }
        if isHovered {
            return .hovered
        }
        return .idle
    }

    private var containerBackground: Color {
        switch visualState {
        case .idle:
            return .white
        case .hovered:
            return Color(red: 245.0 / 255.0, green: 243.0 / 255.0, blue: 255.0 / 255.0)
        case .dragging:
            return Color(red: 237.0 / 255.0, green: 233.0 / 255.0, blue: 254.0 / 255.0)
        }
    }

    private var containerBorder: Color {
        switch visualState {
        case .idle:
            return Color.gray.opacity(0.28)
        case .hovered:
            return Color.brandViolet
        case .dragging:
            return Color.brandViolet
        }
    }

    private var iconBackground: Color {
        visualState == .dragging ? Color.brandViolet : Color.brandYellow
    }

    private var iconForeground: Color {
        visualState == .dragging ? .white : .black
    }

    private var iconShadowOffset: CGFloat {
        visualState == .idle ? 4 : 6
    }

    private var iconScale: CGFloat {
        switch visualState {
        case .idle:
            return 1.0
        case .hovered:
            return 1.1
        case .dragging:
            return 1.1
        }
    }

    private var iconRotation: Double {
        switch visualState {
        case .idle:
            return 0
        case .hovered:
            return 3
        case .dragging:
            return 3
        }
    }

    private var titleText: String {
        visualState == .dragging ? "DROP FILE HERE" : "UPLOAD AUDIO"
    }

    private var titleColor: Color {
        visualState == .idle ? .black : Color.brandViolet
    }

    private var chipBackground: Color {
        visualState == .idle ? Color.gray.opacity(0.08) : .white
    }

    private var chipBorder: Color {
        visualState == .idle ? .clear : .black
    }

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppViewModel, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { viewModel[keyPath: keyPath] = $0 }
        )
    }
}

private enum UploadDropZoneVisualState {
    case idle
    case hovered
    case dragging
}

private struct UploadDropZoneButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.78), value: configuration.isPressed)
    }
}
