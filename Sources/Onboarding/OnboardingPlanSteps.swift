import AppKit
import SwiftUI

// MARK: - Done step

struct PlanStep: View {
    let onChoosePlan: (PidgyPlan) -> Void

    @State private var selected: PidgyPlan = .bundled

    var body: some View {
        VStack(spacing: 0) {
            Text("Pick your plan")
                .font(.custom("Newsreader", size: 36).weight(.medium))
                .tracking(-0.8)
                .foregroundStyle(Color.Pidgy.fg1)

            Text("Both start with a \(Subscription.trialDays)-day free trial. No charge today — cancel anytime before it ends.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 460)

            HStack(alignment: .top, spacing: 14) {
                planCard(
                    .bundled,
                    blurb: "We run the AI — nothing to set up. Reply suggestions, summaries, and semantic search work out of the box.",
                    bullets: ["Zero setup", "Managed AI via our non-logging proxy", "Best for getting started"]
                )
                planCard(
                    .byok,
                    blurb: "Bring your own OpenAI or Claude key. It goes straight to the provider — never through Pidgy. Maximum privacy.",
                    bullets: ["Your key, your bill", "Nothing transits our servers", "For the privacy-max user"]
                )
            }
            .padding(.top, 28)
            .frame(maxWidth: 720)

            OnboardingPrimaryButton(
                title: "Start \(Subscription.trialDays)-day free trial",
                trailingChevron: true,
                action: { onChoosePlan(selected) }
            )
            .padding(.top, 28)

            Text("You can update your AI key anytime in Preferences. Plan changes go through Manage subscription.")
                .font(.system(size: 11))
                .foregroundStyle(Color.Pidgy.fg4)
                .padding(.top, 14)
        }
        .frame(maxWidth: 720)
    }

    @ViewBuilder
    private func planCard(_ plan: PidgyPlan, blurb: String, bullets: [String]) -> some View {
        let isSelected = selected == plan
        Button {
            selected = plan
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(plan.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.Pidgy.fg1)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.Pidgy.accentFg : Color.Pidgy.border2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("$\(plan.monthlyPriceUSD)")
                        .font(.custom("Newsreader", size: 30).weight(.medium))
                        .foregroundStyle(Color.Pidgy.fg1)
                    Text("/mo")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                Text(blurb)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.Pidgy.accentFg)
                                .padding(.top, 2)
                            Text(bullet)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.Pidgy.fg2)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.Pidgy.bg3 : Color.Pidgy.bg2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? Color.Pidgy.accentFg.opacity(0.7) : Color.Pidgy.border2,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(PidgyMotion.easeOut, value: isSelected)
    }
}

struct ByokKeyStep: View {
    @ObservedObject var aiService: AIService
    let onContinue: () -> Void

    @State private var provider: AIProviderConfig.ProviderType = .openai
    @State private var key: String = ""
    @State private var isVerifying = false
    @State private var errorMessage: String?

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add your AI key")
                .font(.custom("Newsreader", size: 36).weight(.medium))
                .tracking(-0.8)
                .foregroundStyle(Color.Pidgy.fg1)

            Text("Your key goes straight to the provider — never through Pidgy. We just verify it works.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 440)

            HStack(spacing: 8) {
                ForEach([AIProviderConfig.ProviderType.openai, .claude], id: \.self) { option in
                    Button {
                        provider = option
                        errorMessage = nil
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(provider == option ? Color.Pidgy.fg1 : Color.Pidgy.fg3)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(provider == option ? Color.Pidgy.bg4 : Color.clear)
                                    .overlay(Capsule().stroke(
                                        provider == option ? Color.Pidgy.accentFg.opacity(0.6) : Color.Pidgy.border2
                                    ))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 22)

            SecureField(provider == .openai ? "sk-…" : "sk-ant-…", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: 440)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg1)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Pidgy.border2))
                )
                .padding(.top, 14)
                .onChange(of: key) { errorMessage = nil }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 8)
            }

            OnboardingPrimaryButton(
                title: isVerifying ? "Verifying…" : "Verify & continue",
                trailingChevron: !isVerifying,
                isDisabled: trimmedKey.isEmpty || isVerifying,
                action: verify
            )
            .padding(.top, 22)

            Button("Skip — I'll add it later in Preferences") { onContinue() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.Pidgy.fg4)
                .padding(.top, 14)
        }
        .frame(maxWidth: 520)
    }

    private func verify() {
        let candidate = trimmedKey
        guard !candidate.isEmpty else { return }
        isVerifying = true
        errorMessage = nil
        // BYO key goes direct to the provider (no proxy endpoint).
        aiService.configure(type: provider, apiKey: candidate)
        Task { @MainActor in
            do {
                let ok = try await aiService.testConnection()
                isVerifying = false
                if ok {
                    onContinue()
                } else {
                    errorMessage = "Couldn't verify that key. Double-check and try again."
                }
            } catch {
                isVerifying = false
                errorMessage = "Couldn't verify that key. Double-check and try again."
            }
        }
    }
}

struct DoneStep: View {
    let onFinish: () -> Void

    @State private var checkScale: CGFloat = 0.4
    @State private var checkOpacity: Double = 0
    /// Asked once, here, right after the user connected Telegram —
    /// pre-selected by detecting whether a tg:// handler is installed.
    /// Changeable any time in Preferences → "Open chats in".
    @State private var chatOpenTarget: ChatOpenTarget = .current

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color(hex: 0x5BD18B).opacity(0.14))
                    .frame(width: 88, height: 88)
                Circle()
                    .stroke(Color(hex: 0x5BD18B).opacity(0.4), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x5BD18B))
            }
            .scaleEffect(checkScale)
            .opacity(checkOpacity)
            .padding(.bottom, 24)

            Text("You're all set")
                .font(.custom("Newsreader", size: 36).weight(.medium))
                .tracking(-0.8)
                .foregroundStyle(Color.Pidgy.fg1)

            Text("Pidgy is now indexing your chats locally. Triage will populate over the next minute.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 440)

            VStack(spacing: 10) {
                Text("Where should chats open?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Pidgy.fg2)
                HStack(spacing: 8) {
                    ForEach(ChatOpenTarget.allCases) { option in
                        Button {
                            chatOpenTarget = option
                            UserDefaults.standard.set(
                                option.rawValue,
                                forKey: AppConstants.Preferences.chatOpenTargetKey
                            )
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(chatOpenTarget == option ? Color.Pidgy.fg1 : Color.Pidgy.fg3)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(chatOpenTarget == option ? Color.Pidgy.bg4 : Color.clear)
                                        .overlay(
                                            Capsule().stroke(
                                                chatOpenTarget == option ? Color.Pidgy.accentFg.opacity(0.6) : Color.Pidgy.border2
                                            )
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("You can change this anytime in Preferences.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Pidgy.fg4)
            }
            .padding(.top, 24)

            OnboardingPrimaryButton(title: "Open Pidgy", trailingChevron: true, action: onFinish)
                .padding(.top, 28)
        }
        .frame(maxWidth: 440)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                checkScale = 1
                checkOpacity = 1
            }
        }
    }
}

// MARK: - Primary button

struct OnboardingPrimaryButton: View {
    let title: String
    let trailingChevron: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                if trailingChevron {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(isDisabled ? Color.Pidgy.fg3 : Color.Pidgy.bg1)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDisabled ? Color.Pidgy.bg3 : Color.Pidgy.fg1.opacity(hovering ? 0.9 : 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
    }
}
