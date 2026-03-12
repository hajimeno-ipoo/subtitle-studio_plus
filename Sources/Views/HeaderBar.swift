import SwiftUI

struct HeaderBar: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        HStack {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.brandViolet)
                    .stroke(Color.black, lineWidth: 2)
                    .frame(width: 42, height: 42)
                    .overlay(Image(systemName: "waveform").font(.title3.weight(.black)).foregroundStyle(.white))
                Text("AI ")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                + Text("Subtitle")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(Color.brandViolet)
                + Text(" Studio")
                    .font(.system(size: 28, weight: .black, design: .rounded))
            }

            Spacer()

            if let asset = viewModel.audioAsset {
                Label(asset.fileName, systemImage: "music.note")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.brandBlue.opacity(0.18))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.black, lineWidth: 2))
                    .lineLimit(1)
            }

            HStack(spacing: 12) {
                Button("Settings") {
                    viewModel.isSettingsPresented = true
                }
                .buttonStyle(StudioSecondaryButton())

                Button("EXPORT .SRT") {
                    viewModel.requestExport()
                }
                .buttonStyle(StudioPrimaryButton(color: .brandGreen))
                .disabled(viewModel.subtitles.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.white)
    }
}

struct StudioPrimaryButton: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .black, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black, lineWidth: 2))
            .shadow(color: .black, radius: 0, x: configuration.isPressed ? 1 : 4, y: configuration.isPressed ? 1 : 4)
            .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
    }
}

struct StudioSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black, lineWidth: 2))
    }
}
