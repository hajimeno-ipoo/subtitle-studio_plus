import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var apiKey = ""
    @State private var revealAPIKey = false
    @State private var statusMessage = ""
    @State private var loadTask: Task<Void, Never>?

    private var isBusy: Bool {
        viewModel.settings.isLoadingAPIKey || viewModel.settings.isSavingAPIKey
    }

    var body: some View {
        @Bindable var bindableViewModel = viewModel
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
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                    } else {
                        SecureField("Gemini API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity)

                Button(revealAPIKey ? "Hide" : "Show") {
                    revealAPIKey.toggle()
                }
                .buttonStyle(StudioSecondaryButton())
                .disabled(isBusy)

                Button("Paste") {
                    if let pasted = NSPasteboard.general.string(forType: .string)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                        apiKey = pasted
                        statusMessage = "API key pasted."
                    } else {
                        statusMessage = "Clipboard is empty."
                    }
                }
                .buttonStyle(StudioSecondaryButton())
                .disabled(isBusy)
            }

            if viewModel.settings.isLoadingAPIKey || viewModel.settings.isSavingAPIKey {
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

            HStack {
                Button("Cancel") {
                    viewModel.isSettingsPresented = false
                }
                .buttonStyle(StudioSecondaryButton())
                .disabled(viewModel.settings.isSavingAPIKey)

                Spacer()

                Button("Save") {
                    let pendingKey = apiKey
                    statusMessage = "Requesting Keychain access..."
                    Task {
                        await viewModel.settings.persist(pendingKey)
                        statusMessage = "API key saved."
                        viewModel.isSettingsPresented = false
                    }
                }
                .buttonStyle(StudioPrimaryButton(color: .brandGreen))
                .disabled(isBusy)
            }

            Divider()
                .padding(.vertical, 12)

            Text("Auto-Align Settings")
                .font(.system(size: 28, weight: .black, design: .rounded))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RMS Window Size (seconds):")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                    Spacer()
                    TextField("", value: $bindableViewModel.settings.autoAlignRMSWindowSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }

                HStack {
                    Text("Threshold Ratio:")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                    Spacer()
                    TextField("", value: $bindableViewModel.settings.autoAlignThresholdRatio, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }

                HStack {
                    Text("Min Gap Fill (seconds):")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                    Spacer()
                    TextField("", value: $bindableViewModel.settings.autoAlignMinGapFill, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }

                Toggle("Use Adaptive Threshold", isOn: $bindableViewModel.settings.autoAlignUseAdaptiveThreshold)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            statusMessage = ""
            loadTask?.cancel()
            loadTask = Task {
                await viewModel.settings.loadIfNeeded()
                guard !Task.isCancelled else { return }
                apiKey = viewModel.settings.geminiAPIKey
            }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }
}
