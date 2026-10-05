//
//  OnboardingSupport.swift
//  Pidgy
//
//  Small shared pieces used by onboarding and Preferences: brand glyphs,
//  the launch-at-login wrapper, the account avatar.
//

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Brand glyphs

struct BrandSVGGlyph: View {
    let name: String
    var inset: CGFloat = 0
    var size: CGFloat = 40

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .scaledToFit()
            .padding(inset)
            .frame(width: size, height: size)
    }
}

// MARK: - Launch at login

/// Thin wrapper over SMAppService so the toggle reads and writes the real
/// login-item state instead of a shadow preference.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Account avatar

struct AccountAvatar: View {
    let profile: AccountService.Profile
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.Pidgy.accentSoftHi)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Color.Pidgy.accentFg)
            if let url = profile.avatarURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let source = profile.displayName ?? profile.email ?? "?"
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
