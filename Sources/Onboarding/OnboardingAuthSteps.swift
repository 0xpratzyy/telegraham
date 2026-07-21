import AppKit
import SwiftUI
import TDLibKit

// MARK: - Auth state convenience

extension AuthState {
    /// Pulls the optional 2FA hint out of `.waitingForPassword(hint:)`.
    /// Returns nil for any other state — the password step degrades to
    /// just the input field if no hint is set on the account.
    var twoFactorPasswordHint: String? {
        if case .waitingForPassword(let hint) = self { return hint }
        return nil
    }
}

// MARK: - Phone-login step

struct PhoneStep: View {
    @Binding var phoneNumber: String
    let errorMessage: String?
    let isSubmitting: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Telegram")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.accentFg)

            Text("Sign in with phone number")
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.top, 8)

            Text("Telegram will text you a 5-digit code. Use international format with the country code.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14)
                .frame(maxWidth: 380)

            OnboardingTextField(
                title: "Phone number",
                placeholder: "+1 555 123 4567",
                text: $phoneNumber
            )
            .padding(.top, 26)
            .frame(maxWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("← Back to QR")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                OnboardingPrimaryButton(
                    title: isSubmitting ? "Sending…" : "Send code",
                    trailingChevron: !isSubmitting,
                    isDisabled: isSubmitting,
                    action: onSubmit
                )
            }
            .padding(.top, 28)
        }
        .frame(maxWidth: 480)
    }
}

// MARK: - Verification code step

struct CodeStep: View {
    let phoneNumber: String
    @Binding var code: String
    let errorMessage: String?
    let isSubmitting: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Telegram")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.accentFg)

            Text("Enter the code")
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.top, 8)

            (
                Text("We sent a 5-digit code to ")
                    .foregroundColor(Color.Pidgy.fg3)
                + Text(phoneNumber.isEmpty ? "your phone" : phoneNumber)
                    .foregroundColor(Color.Pidgy.fg1)
                    .fontWeight(.medium)
                + Text(". Open Telegram on the device that received it if it doesn't auto-fill.")
                    .foregroundColor(Color.Pidgy.fg3)
            )
            .font(.system(size: 13.5))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.top, 14)
            .frame(maxWidth: 400)

            OnboardingTextField(
                title: "Verification code",
                placeholder: "12345",
                text: $code
            )
            .padding(.top, 26)
            .frame(maxWidth: 240)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("← Back")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                OnboardingPrimaryButton(
                    title: isSubmitting ? "Verifying…" : "Verify",
                    trailingChevron: !isSubmitting,
                    isDisabled: isSubmitting,
                    action: onSubmit
                )
            }
            .padding(.top, 28)
        }
        .frame(maxWidth: 480)
    }
}

// MARK: - 2FA password step

struct PasswordStep: View {
    @Binding var password: String
    let hint: String?
    let errorMessage: String?
    let isSubmitting: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Telegram")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.accentFg)

            Text("Two-factor password")
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.top, 8)

            Text("Your account has 2FA on. Enter the cloud password you set in Telegram → Privacy → Two-Step Verification.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14)
                .frame(maxWidth: 400)

            if let hint, !hint.isEmpty {
                Text("Hint: \(hint)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.fg2)
                    .padding(.top, 8)
            }

            OnboardingTextField(
                title: "Password",
                placeholder: "Your 2FA password",
                text: $password,
                isSecure: true
            )
            .padding(.top, 24)
            .frame(maxWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("← Back")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                OnboardingPrimaryButton(
                    title: isSubmitting ? "Verifying…" : "Sign in",
                    trailingChevron: !isSubmitting,
                    isDisabled: isSubmitting,
                    action: onSubmit
                )
            }
            .padding(.top, 28)
        }
        .frame(maxWidth: 480)
    }
}

// MARK: - Shared text field for the auth steps

private struct OnboardingTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: PidgySpace.s1) {
            Text(title)
                .font(Font.Pidgy.eyebrow)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.fg3)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Font.Pidgy.body)
            .padding(PidgySpace.s3)
            .background(Color.Pidgy.bg3)
            .cornerRadius(PidgyRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: PidgyRadius.sm, style: .continuous)
                    .stroke(Color.Pidgy.border2, lineWidth: 1)
            )
        }
    }
}
