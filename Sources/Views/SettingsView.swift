import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Gemini Settings")
                .font(.system(size: 28, weight: .black, design: .rounded))
            Text("Store your Gemini API key in the macOS Keychain. The key stays on this Mac.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            SecureField("Gemini API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium, design: .monospaced))

            HStack {
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
            apiKey = viewModel.settings.geminiAPIKey
        }
    }
}
