import SwiftUI
import UniformTypeIdentifiers

struct UploadDropZone: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(viewModel.isDropTargeted ? Color.brandViolet.opacity(0.18) : .white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .strokeBorder(viewModel.isDropTargeted ? Color.brandViolet : Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 4, dash: [14]))
                        )
                        .frame(maxWidth: 860, minHeight: 320)

                    VStack(spacing: 18) {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(viewModel.isDropTargeted ? Color.brandViolet : Color.brandYellow)
                            .stroke(.black, lineWidth: 2)
                            .frame(width: 100, height: 100)
                            .overlay(Image(systemName: "square.and.arrow.down").font(.system(size: 42, weight: .black)))

                        Text(viewModel.isDropTargeted ? "DROP FILE HERE" : "UPLOAD AUDIO")
                            .font(.system(size: 38, weight: .black, design: .rounded))
                        Text("MP3, WAV, M4A, MP4 and more. Max 100MB.")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.gray.opacity(0.08))
                            .clipShape(Capsule())

                        Button("Choose File") {
                            viewModel.requestOpenAudio()
                        }
                        .buttonStyle(StudioPrimaryButton(color: .brandYellow))
                    }
                }
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

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppViewModel, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { viewModel[keyPath: keyPath] = $0 }
        )
    }
}
