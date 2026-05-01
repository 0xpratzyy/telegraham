import SwiftUI
import TDLibKit
import CoreImage.CIFilterBuiltins

struct AuthView: View {
    @EnvironmentObject var telegramService: TelegramService
    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @State private var password = ""
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var showPhoneLogin = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                PidgyMascotMark(size: 58)
                Text("Pidgy")
                    .font(Font.Pidgy.h2)
                    .foregroundStyle(Color.Pidgy.fg1)
            }
            .padding(.top, PidgySpace.s8)
            .padding(.bottom, PidgySpace.s6)

            // Content based on auth state
            Group {
                switch telegramService.authState {
                case .uninitialized, .waitingForParameters:
                    credentialsView
                case .waitingForPhoneNumber:
                    if showPhoneLogin {
                        phoneNumberView
                    } else {
                        qrCodeRequestView
                    }
                case .waitingForQrCode(let link):
                    qrCodeView(link: link)
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
                        .foregroundStyle(Color.Pidgy.fg2)
                }
            }
            .padding(.horizontal, PidgySpace.s8)

            if let error = errorMessage {
                Text(error)
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, PidgySpace.s3)
                    .padding(.horizontal, PidgySpace.s8)
            }

            Spacer()

            // Safety notice
            Text("Pidgy is read-only. It can never send messages or modify your account.")
                .font(Font.Pidgy.meta)
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PidgySpace.s8)
                .padding(.bottom, PidgySpace.s5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Pidgy.bg1)
        .onAppear {
            apiId = (try? KeychainManager.retrieve(for: .apiId)) ?? ""
            apiHash = (try? KeychainManager.retrieve(for: .apiHash)) ?? ""
        }
    }

    // MARK: - Credential Input

    private var credentialsView: some View {
        VStack(spacing: 16) {
            Text("Enter your Telegram API credentials")
                .font(Font.Pidgy.body)
                .foregroundStyle(Color.Pidgy.fg2)

            VStack(spacing: 12) {
                inputField(title: "API ID", text: $apiId, placeholder: "e.g., 12345678")
                inputField(title: "API Hash", text: $apiHash, placeholder: "e.g., abc123def456...", isSecure: true)
            }

            Link("Get credentials from my.telegram.org", destination: URL(string: "https://my.telegram.org")!)
                .font(Font.Pidgy.bodySm)
                .foregroundStyle(Color.Pidgy.accent)

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

    // MARK: - QR Code Login

    private var qrCodeRequestView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)

            Text("Requesting QR code...")
                .font(Font.Pidgy.body)
                .foregroundStyle(Color.Pidgy.fg2)
        }
        .onAppear {
            Task {
                do {
                    try await telegramService.requestQrCodeAuth()
                } catch {
                    errorMessage = Self.extractErrorMessage(error)
                }
            }
        }
    }

    private func qrCodeView(link: String) -> some View {
        VStack(spacing: 20) {
            Text("Scan with Telegram")
                .font(Font.Pidgy.h3)
                .foregroundStyle(Color.Pidgy.fg1)

            if let qrImage = generateQRCode(from: link) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.Pidgy.bg4)
                    .frame(width: 200, height: 200)
                    .overlay {
                        Text("Failed to generate QR")
                            .font(Font.Pidgy.bodySm)
                            .foregroundStyle(Color.Pidgy.fg2)
                    }
            }

            VStack(spacing: 6) {
                Text("Open Telegram on your phone")
                Text("Go to **Settings → Devices → Link Desktop Device**")
                Text("Point your phone at this QR code")
            }
            .font(Font.Pidgy.bodySm)
            .foregroundStyle(Color.Pidgy.fg2)
            .multilineTextAlignment(.center)

            Button {
                showPhoneLogin = true
            } label: {
                Text("Log in with phone number instead")
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Phone Number

    private var phoneNumberView: some View {
        VStack(spacing: 16) {
            Text("Enter your phone number")
                .font(Font.Pidgy.body)
                .foregroundStyle(Color.Pidgy.fg2)

            inputField(title: "Phone Number", text: $phoneNumber, placeholder: "+1 234 567 8900")

            actionButton(title: "Send Code") {
                do {
                    errorMessage = nil
                    try await telegramService.setPhoneNumber(phoneNumber)
                } catch {
                    errorMessage = Self.extractErrorMessage(error)
                }
            }

            Button {
                showPhoneLogin = false
            } label: {
                Text("Log in with QR code instead")
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Verification Code

    private func verificationCodeView(codeInfo: CodeInfo?) -> some View {
        VStack(spacing: 16) {
            Text("Enter the verification code")
                .font(Font.Pidgy.body)
                .foregroundStyle(Color.Pidgy.fg2)

            if let info = codeInfo, !info.phoneNumber.isEmpty {
                Text("Sent to \(info.phoneNumber)")
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.fg3)
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
                .font(Font.Pidgy.body)
                .foregroundStyle(Color.Pidgy.fg2)

            if let hint, !hint.isEmpty {
                Text("Hint: \(hint)")
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.fg3)
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
                .font(Font.Pidgy.displayH1)
                .foregroundStyle(Color.Pidgy.success)

            Text("Connected to Telegram")
                .font(Font.Pidgy.h3)
                .foregroundStyle(Color.Pidgy.fg1)

            if let user = telegramService.currentUser {
                Text(user.displayName)
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.fg2)
            }
        }
    }

    // MARK: - QR Code Generator

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    // MARK: - Reusable Components

    private func inputField(title: String, text: Binding<String>, placeholder: String, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Font.Pidgy.eyebrow)
                .foregroundStyle(Color.Pidgy.fg3)
                .textCase(.uppercase)

            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(Font.Pidgy.body)
            .padding(PidgySpace.s3)
            .background(Color.Pidgy.bg3)
            .cornerRadius(PidgyRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: PidgyRadius.sm)
                    .stroke(Color.Pidgy.border2, lineWidth: 1)
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
                    .font(Font.Pidgy.bodyMd)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, PidgySpace.s3)
            .background(Color.Pidgy.accent)
            .foregroundColor(Color.white)
            .cornerRadius(PidgyRadius.sm)
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
