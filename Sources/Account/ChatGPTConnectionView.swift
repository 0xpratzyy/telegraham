import SwiftUI

/// ChatGPT authorization is separate from Pidgy's optional invite/license account.
struct ChatGPTConnectionView: View {
    @EnvironmentObject private var aiService: AIService
    @ObservedObject private var connection = ChatGPTService.shared
    @State private var errorMessage: String?
    @State private var working = false
    @State private var testResult: String?
    var compact = false

    var body: some View {
        if BundledSecrets.chatGPTLocalOSS { connectionContent }
    }

    private var connectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
                Text("Use your ChatGPT plan").font(.headline)
                Text("Eligible AI requests use your ChatGPT allowance or credits. This is separate from Pidgy's paid plan. ChatGPT conversations aren't imported.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let active = connection.active {
                Text(active.label).font(.callout).textSelection(.enabled)
                Text(active.canUsePlan ? (aiService.providerType == .chatgpt ? "Using ChatGPT plan" : "Connected · choose Use this model to enable") : "Sign in again to enable ChatGPT plan usage.")
                    .font(.caption).foregroundStyle(.secondary)
                if active.canUsePlan && !compact {
                    if !connection.models.isEmpty {
                        Picker("Model", selection: $connection.selectedModel) {
                            ForEach(connection.models) { Text($0.display_name).tag($0.slug) }
                        }
                        Button("Use this model") {
                            perform {
                                try connection.saveModel()
                                aiService.activateChatGPT(model: connection.selectedModel)
                            }
                        }
                        .disabled(connection.selectedModel.isEmpty)
                    }
                    Toggle("Allow background fact extraction", isOn: Binding(
                        get: { connection.backgroundEnabled }, set: { connection.backgroundEnabled = $0 }
                    ))
                    Text("Background fact extraction can use many requests and is off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh models") { perform { try await connection.loadModels() } }
                    Button("Test connection") {
                        perform {
                            testResult = nil
                            let success = try await aiService.testConnection()
                            testResult = success ? "Connected · test response received using your ChatGPT plan." : "Connection test failed."
                        }
                    }
                    .disabled(aiService.providerType != .chatgpt)
                    Text("The connection test sends a small request using your plan allowance.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                }
                if !compact {
                    Picker("Saved ChatGPT account", selection: Binding(
                        get: { connection.activeID ?? "" },
                        set: { id in perform {
                            if aiService.providerType == .chatgpt { aiService.configure(type: .none, apiKey: "") }
                            try await connection.selectAccount(id)
                            if connection.active?.canUsePlan == true { aiService.activateChatGPT(model: connection.selectedModel) }
                        } }
                    )) {
                        ForEach(connection.registrations) { Text($0.label).tag($0.id) }
                    }
                }
                if compact && active.canUsePlan {
                    HStack {
                        if aiService.providerType != .chatgpt {
                            Button("Use ChatGPT plan") {
                                perform {
                                    if connection.models.isEmpty { try await connection.loadModels() }
                                    try connection.saveModel()
                                    aiService.activateChatGPT(model: connection.selectedModel)
                                }
                            }
                        }
                        Button("Change account") { signIn() }
                    }
                } else {
                  HStack {
                    Button("Continue with ChatGPT") { signIn(id: active.id, enablePlan: !active.canUsePlan) }
                    Button("Sign out") {
                        perform {
                            if aiService.providerType == .chatgpt { aiService.configure(type: .none, apiKey: "") }
                            try await connection.signOut()
                        }
                    }
                  }
                }
            } else {
                if !connection.registrations.isEmpty && !compact {
                    ForEach(connection.registrations) { account in
                        Button("Continue as \(account.label)") { signIn(id: account.id) }
                    }
                }
                Button("Continue with ChatGPT") { signIn() }
            }
            if !compact && connection.active != nil {
                Button("Add another ChatGPT account") { signIn() }
            }
            Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)
            if let status = connection.status, !compact { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if working || connection.isBusy {
                HStack { ProgressView().controlSize(.small); Text("Connecting…").font(.caption)
                    Button("Cancel") { connection.cancelSignIn() }
                }
            }
        }
        .disabled(working || connection.isBusy)
        .overlay(alignment: .bottomTrailing) {
            if connection.isBusy { Button("Cancel sign-in") { connection.cancelSignIn() }.font(.caption) }
        }
        .padding(compact ? 0 : 16)
        .background(compact ? Color.clear : Color.Pidgy.bg2, in: RoundedRectangle(cornerRadius: 14))
        .alert("You're using your ChatGPT plan", isPresented: Binding(
            get: { connection.showWelcome }, set: { if !$0 { connection.dismissWelcome() } }
        )) {
            Button("Got it") { connection.dismissWelcome() }
        } message: {
            Text("Eligible AI requests in Pidgy use your ChatGPT plan or credits. Manage limits and access in ChatGPT settings. Background fact extraction starts only when you enable it.")
        }
        .task {
            if connection.active?.canUsePlan == true && connection.models.isEmpty && !compact {
                do { try await connection.loadModels() } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    private func signIn(id: String? = nil, enablePlan: Bool = false) {
        perform {
            try await connection.signIn(registrationID: id, enablePlan: enablePlan)
            if connection.active?.canUsePlan == true && !connection.selectedModel.isEmpty {
                aiService.activateChatGPT(model: connection.selectedModel)
            }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working && !connection.isBusy else { return }
        working = true; errorMessage = nil
        Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
