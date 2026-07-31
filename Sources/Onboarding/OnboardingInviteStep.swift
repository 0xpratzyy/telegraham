//
//  OnboardingInviteStep.swift
//  Pidgy
//
//  Beta invite gate — sits between Welcome and the Tour. Hard gate: the
//  flow can't advance without a server-validated code (InviteService).
//  Only shown when the build bundles the proxy (InviteService.gateRequired)
//  and the install isn't already registered.
//

import SwiftUI

struct InviteStep: View {
    let onRedeemed: () -> Void
    let onBack: () -> Void

    @ObservedObject private var inviteService = InviteService.shared
    @State private var code: String = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0x7BA3F0).opacity(0.2), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)
                Image(systemName: "ticket")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Color(hex: 0x7BA3F0))
                    .rotationEffect(.degrees(-8))
            }
            .padding(.bottom, 22)

            Text("Pidgy is invite-only")
                .font(.custom("Newsreader", size: 32).weight(.medium))
                .tracking(-0.7)
                .foregroundStyle(Color.Pidgy.fg1)

            Text("The beta grows one friend at a time. Enter the invite code you were given — you'll get your own codes to share once you're in.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 440)

            TextField("PIDGY-ABC123", text: $code)
                .textFieldStyle(.plain)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(Color.Pidgy.fg1)
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: 280)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(errorMessage == nil ? Color.Pidgy.border2 : Color.Pidgy.danger.opacity(0.7))
                        )
                )
                .padding(.top, 22)
                .onChange(of: code) { errorMessage = nil }
                .onSubmit { redeem() }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .frame(maxWidth: 400)
            }

            OnboardingPrimaryButton(
                title: inviteService.isRedeeming ? "Checking…" : "Unlock the beta",
                trailingChevron: !inviteService.isRedeeming,
                isDisabled: trimmedCode.isEmpty || inviteService.isRedeeming,
                action: redeem
            )
            .padding(.top, 22)

            Button("Back") { onBack() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.Pidgy.fg4)
                .padding(.top, 14)

            #if DEBUG
            // Dev convenience only — never compiled into Release, so the
            // distributed beta stays a true hard gate.
            Button("Skip (debug build)") { onRedeemed() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.Pidgy.fg4.opacity(0.7))
                .padding(.top, 6)
            #endif
        }
        .frame(maxWidth: 520)
        .onAppear { fieldFocused = true }
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func redeem() {
        let candidate = trimmedCode
        guard !candidate.isEmpty, !inviteService.isRedeeming else { return }
        errorMessage = nil
        Task { @MainActor in
            do {
                try await InviteService.shared.redeem(code: candidate)
                onRedeemed()
            } catch let error as InviteService.RedeemError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = InviteService.RedeemError.network.errorDescription
            }
        }
    }
}

// MARK: - Code chip (shared: onboarding Done step + Preferences → Invites)

/// One invite code as a click-to-copy chip. A redeemed code stays visible
/// but dimmed + struck, so the "who used what" story reads at a glance.
struct InviteCodeChip: View {
    let code: InviteService.PersonalCode

    @State private var copied = false

    var body: some View {
        Button {
            guard !code.redeemed else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.code, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 6) {
                Text(code.code)
                    .font(.system(size: 12, design: .monospaced))
                    .strikethrough(code.redeemed)
                Image(systemName: copied ? "checkmark" : (code.redeemed ? "person.fill.checkmark" : "doc.on.doc"))
                    .font(.system(size: 10))
            }
            .foregroundStyle(code.redeemed ? Color.Pidgy.fg4 : Color.Pidgy.fg2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.Pidgy.bg1)
                    .overlay(Capsule().stroke(copied ? Color.Pidgy.accentFg.opacity(0.6) : Color.Pidgy.border2))
            )
        }
        .buttonStyle(.pidgyPress)
        .disabled(code.redeemed)
        .help(code.redeemed ? "Already used — this friend is in" : "Click to copy")
    }
}
