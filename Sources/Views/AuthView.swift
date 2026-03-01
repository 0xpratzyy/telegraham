import SwiftUI
import TDLibKit

struct AuthView: View {
    @EnvironmentObject var telegramService: TelegramService
    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @State private var password = ""
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("TGSearch")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // Content based on auth state
            Group {
                switch telegramService.authState {
                case .uninitialized, .waitingForParameters:
                    credentialsView
                case .waitingForPhoneNumber:
                    phoneNumberView
                case .waitingForCode(let codeInfo):
                    verificationCodeView(codeInfo: codeInfo)
                case .waitingForPassword(let hint):
                    passwordView(hint: hint)
                case .ready:
                    readyView
                case .loggingOut, .closing:
                    ProgressView("Disconnecting...")
                case .closed:
                    Text("Session closed")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 12)
                    .padding(.horizontal, 32)
            }

            Spacer()

            // Safety notice
            Text("TGSearch is read-only. It can never send messages or modify your account.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            apiId = (try? KeychainManager.retrieve(for: .apiId)) ?? ""
            apiHash = (try? KeychainManager.retrieve(for: .apiHash)) ?? ""
        }
    }

    // MARK: - Credential Input

    private var credentialsView: some View {
        VStack(spacing: 16) {
            Text("Enter your Telegram API credentials")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                inputField(title: "API ID", text: $apiId, placeholder: "e.g., 12345678")
                inputField(title: "API Hash", text: $apiHash, placeholder: "e.g., abc123def456...", isSecure: true)
            }

            Link("Get credentials from my.telegram.org", destination: URL(string: "https://my.telegram.org")!)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)

            actionButton(title: "Connect") {
                guard !apiId.isEmpty, !apiHash.isEmpty else {
                    errorMessage = "Both API ID and API Hash are required"
                    return
                }
                do {
                    try KeychainManager.save(apiId, for: .apiId)
                    try KeychainManager.save(apiHash, for: .apiHash)
                    guard let id = Int(apiId) else {
                        errorMessage = "API ID must be a number"
                        return
                    }
                    errorMessage = nil
                    await telegramService.start(apiId: id, apiHash: apiHash)
                } catch {
                    errorMessage = Self.extractErrorMessage(error)
                }
            }
        }
    }

    // MARK: - Phone Number

    private var phoneNumberView: some View {
        VStack(spacing: 16) {
            Text("Enter your phone number")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            inputField(title: "Phone Number", text: $phoneNumber, placeholder: "+1 234 567 8900")

            actionButton(title: "Send Code") {
                do {
                    errorMessage = nil
                    try await telegramService.setPhoneNumber(phoneNumber)
                } catch {
                    errorMessage = Self.extractErrorMessage(error)
                }
            }
        }
    }

    // MARK: - Verification Code

    private func verificationCodeView(codeInfo: CodeInfo?) -> some View {
        VStack(spacing: 16) {
            Text("Enter the verification code")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            if let info = codeInfo, !info.phoneNumber.isEmpty {
                Text("Sent to \(info.phoneNumber)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            inputField(title: "Code", text: $verificationCode, placeholder: "12345")

            actionButton(title: "Verify") {
                do {
                    errorMessage = nil
                    try await telegramService.submitVerificationCode(verificationCode)
                } catch {
                    errorMessage = Self.extractErrorMessage(error)
                }
            }
        }
    }

    // MARK: - Password (2FA)

    private func passwordView(hint: String?) -> some View {
        VStack(spacing: 16) {
            Text("Enter your two-factor authentication password")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            if let hint, !hint.isEmpty {
                Text("Hint: \(hint)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            inputField(title: "Password", text: $password, placeholder: "Your 2FA password", isSecure: true)

            actionButton(title: "Submit") {
                do {
                    errorMessage = nil
                    try await telegramService.submitPassword(password)
                } catch {
                    errorMessage = Self.extractErrorMessage(error)
                }
            }
        }
    }

    // MARK: - Authenticated

    private var readyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text("Connected to Telegram")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            if let user = telegramService.currentUser {
                Text(user.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reusable Components

    private func inputField(title: String, text: Binding<String>, placeholder: String, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(10)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
    }

    private func actionButton(title: String, action: @escaping () async -> Void) -> some View {
        Button {
            isSubmitting = true
            Task {
                await action()
                isSubmitting = false
            }
        } label: {
            HStack {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    // MARK: - Error Helpers

    private static func extractErrorMessage(_ error: Swift.Error) -> String {
        if let tdError = error as? TDLibKit.Error {
            return "Error \(tdError.code): \(tdError.message)"
        }
        return error.localizedDescription
    }
}
