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
                Text("Subtitle")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                + Text("Studio")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(Color.brandViolet)
                + Text("Plus")
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
    var textColor: Color = .black

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, color: color, textColor: textColor)
    }

    struct ButtonBody: View {
        let configuration: Configuration
        let color: Color
        let textColor: Color
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(color)
                .brightness(isHovered ? 0.12 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .studioOffsetShadow(
                    cornerRadius: 10,
                    x: configuration.isPressed ? 1 : 3,
                    y: configuration.isPressed ? 1 : 3
                )
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black, lineWidth: 2))
                .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
                .onHover { masking in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovered = masking
                    }
                }
        }
    }
}

struct StudioSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration)
    }

    struct ButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(isHovered ? Color.brandBlue.opacity(0.1) : Color.white)
                .brightness(isHovered ? 0.08 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black, lineWidth: 2))
                .onHover { masking in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovered = masking
                    }
                }
        }
    }
}

struct StudioCircleButton: ButtonStyle {
    var color: Color
    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, color: color, size: size)
    }

    struct ButtonBody: View {
        let configuration: Configuration
        let color: Color
        let size: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(color)
                .brightness(isHovered ? 0.12 : 0)
                .clipShape(Circle())
                .studioOffsetShadow(
                    cornerRadius: size/2,
                    x: configuration.isPressed ? 1 : 3,
                    y: configuration.isPressed ? 1 : 3
                )
                .overlay(Circle().stroke(.black, lineWidth: 2))
                .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
                .onHover { masking in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovered = masking
                    }
                }
        }
    }
}

struct StudioIconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration)
    }

    struct ButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? Color.brandViolet : .black)
                .padding(6)
                .background(isHovered ? Color.brandViolet.opacity(0.12) : Color.clear)
                .clipShape(Circle())
                .contentShape(Rectangle())
                .onHover { masking in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = masking
                    }
                }
                .opacity(configuration.isPressed ? 0.7 : 1.0)
        }
    }
}
