import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var telegramService: TelegramService
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var saveStatus: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        TabView {
            credentialsTab
                .tabItem {
                    Label("Credentials", systemImage: "key")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 350)
        .onAppear {
            loadCredentials()
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

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.39, green: 0.40, blue: 0.95), Color(red: 0.55, green: 0.36, blue: 0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("TGSearch")
                .font(.system(size: 20, weight: .bold, design: .monospaced))

            Text("Version 1.0.0")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("Spotlight for Telegram")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Read-only access. Your data stays on your machine.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text("Open Source (MIT License)")
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

    private func deleteAllData() {
        // Delete keychain entries
        try? KeychainManager.delete(for: .apiId)
        try? KeychainManager.delete(for: .apiHash)

        // Delete TDLib database
        let dbPath = TDLibClientWrapper.databasePath()
        try? FileManager.default.removeItem(atPath: dbPath)

        // Reset state
        apiId = ""
        apiHash = ""
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
        case .waitingForRegistration: return "Registration needed"
        }
    }
}
