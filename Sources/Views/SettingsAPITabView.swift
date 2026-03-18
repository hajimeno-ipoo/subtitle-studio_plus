import SwiftUI

struct SettingsAPITabView: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var revealAPIKey = false
    @State private var statusMessage = ""

    private var isBusy: Bool {
        viewModel.settings.isLoadingAPIKey || viewModel.settings.isSavingAPIKey
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API")
                        .font(.system(size: 28, weight: .black, design: .rounded))

                    Text("Gemini API Key を Keychain に保存します。キーはこの Mac の外には出しません。")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        if revealAPIKey {
                            TextField("Gemini API Key", text: $apiKey)
                        } else {
                            SecureField("Gemini API Key", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))

                    HStack(spacing: 12) {
                        Button(revealAPIKey ? "Hide" : "Show", action: toggleAPIKeyVisibility)
                            .buttonStyle(StudioSecondaryButton())
                            .disabled(isBusy)

                        Button("Paste", action: pasteAPIKey)
                            .buttonStyle(StudioSecondaryButton())
                            .disabled(isBusy)
                    }

                    if isBusy {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)

                            Text(viewModel.settings.isSavingAPIKey ? "Saving to Keychain..." : "Loading from Keychain...")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.brandViolet)
                        }
                    }

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.brandViolet)
                    }
                }
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black, lineWidth: 2))

                HStack {
                    Button("Cancel", action: dismissWindow)
                        .buttonStyle(StudioSecondaryButton())
                        .disabled(viewModel.settings.isSavingAPIKey)

                    Spacer()

                    Button("Save", action: saveAPIKey)
                        .buttonStyle(StudioPrimaryButton(color: .brandGreen))
                        .disabled(isBusy)
                }
            }
            .padding(20)
        }
        .task {
            await loadSettings()
        }
    }

    @MainActor
    private func loadSettings() async {
        await viewModel.settings.loadIfNeeded()
        apiKey = viewModel.settings.geminiAPIKey
    }

    private func toggleAPIKeyVisibility() {
        revealAPIKey.toggle()
    }

    private func pasteAPIKey() {
        if let pasted = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pasted.isEmpty {
            apiKey = pasted
            statusMessage = "API key pasted."
        } else {
            statusMessage = "Clipboard is empty."
        }
    }

    private func saveAPIKey() {
        let pendingKey = apiKey
        statusMessage = "Requesting Keychain access..."

        Task {
            await viewModel.settings.persist(pendingKey)
            await MainActor.run {
                dismissWindow()
            }
        }
    }

    private func dismissWindow() {
        dismiss()
    }
}
