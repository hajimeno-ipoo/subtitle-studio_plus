import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var apiKey = ""
    @State private var revealAPIKey = false
    @State private var statusMessage = ""
    @FocusState private var isAPIKeyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Gemini Settings")
                .font(.system(size: 28, weight: .black, design: .rounded))
            Text("Store your Gemini API key in the macOS Keychain. The key stays on this Mac.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Group {
                    if revealAPIKey {
                        TextField("Gemini API Key", text: $apiKey)
                    } else {
                        SecureField("Gemini API Key", text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .focused($isAPIKeyFocused)

                Button(revealAPIKey ? "Hide" : "Show") {
                    revealAPIKey.toggle()
                    isAPIKeyFocused = true
                }
                .buttonStyle(StudioSecondaryButton())

                Button("Paste") {
                    if let pasted = NSPasteboard.general.string(forType: .string)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                        apiKey = pasted
                        statusMessage = "API key pasted."
                    } else {
                        statusMessage = "Clipboard is empty."
                    }
                    isAPIKeyFocused = true
                }
                .buttonStyle(StudioSecondaryButton())
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.brandViolet)
            }

            HStack {
                Button("Cancel") {
                    viewModel.isSettingsPresented = false
                }
                .buttonStyle(StudioSecondaryButton())

                Spacer()

                Button("Save") {
                    viewModel.settings.geminiAPIKey = apiKey
                    viewModel.settings.persist()
                    viewModel.isSettingsPresented = false
                }
                .buttonStyle(StudioPrimaryButton(color: .brandGreen))
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            viewModel.settings.loadIfNeeded()
            apiKey = viewModel.settings.geminiAPIKey
            statusMessage = ""
            isAPIKeyFocused = true
        }
    }
}
