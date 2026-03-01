import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var saveStatus: String?
    @State private var showDeleteConfirmation = false

    // AI settings
    @State private var selectedAIProvider: AIProviderConfig.ProviderType = .none
    @State private var aiApiKey = ""
    @State private var aiModel = ""
    @State private var aiSaveStatus: String?
    @State private var isTestingConnection = false
    @State private var testConnectionResult: String?

    var body: some View {
        TabView {
            credentialsTab
                .tabItem {
                    Label("Credentials", systemImage: "key")
                }

            aiTab
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadCredentials()
            loadAIConfig()
        }
    }

    // MARK: - Credentials Tab

    private var credentialsTab: some View {
        Form {
            Section {
                TextField("API ID", text: $apiId)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Hash", text: $apiHash)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Credentials") {
                        saveCredentials()
                    }

                    if let status = saveStatus {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundColor(status.contains("Error") ? .red : .green)
                    }
                }

                Link("Get credentials from my.telegram.org",
                     destination: URL(string: "https://my.telegram.org")!)
                    .font(.system(size: 12))
            } header: {
                Text("Telegram API Credentials")
            } footer: {
                Text("Each user must generate their own credentials. Never use someone else's API credentials.")
                    .font(.system(size: 11))
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        StatusDot(isConnected: telegramService.authState == .ready)
                        Text(authStateDescription)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                if telegramService.authState == .ready {
                    if let user = telegramService.currentUser {
                        HStack {
                            Text("Account")
                            Spacer()
                            Text(user.displayName)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button("Log Out") {
                        Task {
                            try? await telegramService.logOut()
                        }
                    }
                    .foregroundColor(.red)
                }
            } header: {
                Text("Account")
            }

            Section {
                Button("Delete All Local Data") {
                    showDeleteConfirmation = true
                }
                .foregroundColor(.red)
            } header: {
                Text("Data")
            } footer: {
                Text("Removes TDLib database, credentials, and all local data. You'll need to re-authenticate.")
                    .font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
        .alert("Delete All Data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("This will remove all local data including your Telegram session. You will need to re-authenticate.")
        }
    }

    // MARK: - AI Tab

    private var aiTab: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedAIProvider) {
                    Text("None").tag(AIProviderConfig.ProviderType.none)
                    Text("Claude (Anthropic)").tag(AIProviderConfig.ProviderType.claude)
                    Text("OpenAI").tag(AIProviderConfig.ProviderType.openai)
                }

                if selectedAIProvider != .none {
                    SecureField("API Key", text: $aiApiKey)
                        .textFieldStyle(.roundedBorder)

                    TextField("Model (optional, uses default if empty)", text: $aiModel)
                        .textFieldStyle(.roundedBorder)

                    Text("Default: \(selectedAIProvider.defaultModel)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack {
                        Button("Save AI Settings") {
                            saveAIConfig()
                        }

                        if let status = aiSaveStatus {
                            Text(status)
                                .font(.system(size: 12))
                                .foregroundColor(status.contains("Error") ? .red : .green)
                        }
                    }

                    HStack {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(isTestingConnection || aiApiKey.isEmpty)

                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let result = testConnectionResult {
                            Text(result)
                                .font(.system(size: 12))
                                .foregroundColor(result.contains("✓") ? .green : .red)
                        }
                    }
                }
            } header: {
                Text("AI Provider")
            } footer: {
                Text("Your own API key is used. No data is stored on any server beyond what the AI provider processes.")
                    .font(.system(size: 11))
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(aiService.isConfigured ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(aiService.isConfigured ? "Configured (\(aiService.providerType.rawValue))" : "Not configured")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

            } header: {
                Text("Privacy")
            } footer: {
                Text("AI features send only message text and sender first names. No phone numbers, user IDs, or media files are ever sent.")
                    .font(.system(size: 11))
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What data is sent to AI:")
                        .font(.system(size: 12, weight: .semibold))
                    Text("- Message text (plaintext)")
                        .font(.system(size: 11))
                    Text("- Sender first name")
                        .font(.system(size: 11))
                    Text("- Relative timestamp (e.g. \"2h ago\")")
                        .font(.system(size: 11))
                    Text("- Chat name")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What is never sent:")
                        .font(.system(size: 12, weight: .semibold))
                    Text("- Phone numbers, user IDs, session tokens")
                        .font(.system(size: 11))
                    Text("- Media files, stickers, voice messages")
                        .font(.system(size: 11))
                    Text("- Last names, full chat histories")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            } header: {
                Text("Privacy Details")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.accentColor, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("TGSearch")
                .font(.system(size: 20, weight: .bold, design: .monospaced))

            Text("Version \(AppConstants.App.version)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("AI-Powered Telegram Search")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Read-only access. Your data stays on your machine.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("Global Hotkey: ⌘ + ⇧ + T")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func loadCredentials() {
        apiId = (try? KeychainManager.retrieve(for: .apiId)) ?? ""
        apiHash = (try? KeychainManager.retrieve(for: .apiHash)) ?? ""
    }

    private func saveCredentials() {
        do {
            try KeychainManager.save(apiId, for: .apiId)
            try KeychainManager.save(apiHash, for: .apiHash)
            saveStatus = "Saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                saveStatus = nil
            }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func loadAIConfig() {
        selectedAIProvider = aiService.providerType
        aiApiKey = (try? KeychainManager.retrieve(for: .aiApiKey)) ?? ""
        aiModel = (try? KeychainManager.retrieve(for: .aiModel)) ?? ""
    }

    private func saveAIConfig() {
        aiService.configure(type: selectedAIProvider, apiKey: aiApiKey, model: aiModel.isEmpty ? nil : aiModel)
        aiSaveStatus = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            aiSaveStatus = nil
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        testConnectionResult = nil
        defer { isTestingConnection = false }

        // Save config first to ensure provider is up to date
        saveAIConfig()

        do {
            let success = try await aiService.testConnection()
            testConnectionResult = success ? "✓ Connection successful" : "✗ Test failed"
        } catch {
            testConnectionResult = "✗ \(error.localizedDescription)"
        }

        // Clear result after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            testConnectionResult = nil
        }
    }

    private func deleteAllData() {
        try? KeychainManager.delete(for: .apiId)
        try? KeychainManager.delete(for: .apiHash)
        try? KeychainManager.delete(for: .aiProviderType)
        try? KeychainManager.delete(for: .aiApiKey)
        try? KeychainManager.delete(for: .aiModel)

        let dbPath = TDLibClientWrapper.databasePath()
        try? FileManager.default.removeItem(atPath: dbPath)

        apiId = ""
        apiHash = ""
        aiApiKey = ""
        aiModel = ""
        selectedAIProvider = .none
        saveStatus = "All data deleted"
    }

    private var authStateDescription: String {
        switch telegramService.authState {
        case .uninitialized: return "Not initialized"
        case .waitingForParameters: return "Configuring..."
        case .waitingForPhoneNumber: return "Waiting for phone"
        case .waitingForCode: return "Waiting for code"
        case .waitingForPassword: return "Waiting for password"
        case .ready: return "Connected"
        case .loggingOut: return "Logging out..."
        case .closing: return "Closing..."
        case .closed: return "Disconnected"
        }
    }
}
