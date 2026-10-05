//
//  InviteCodeChip.swift
//  Pidgy
//
//  One invite code as a click-to-copy chip. Shared by the onboarding Done
//  turn and Preferences → Invites.
//

import AppKit
import SwiftUI

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
