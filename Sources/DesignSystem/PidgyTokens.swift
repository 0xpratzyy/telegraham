//
//  PidgyTokens.swift
//  Pidgy
//
//  Mirrors the Pidgy design-system token export. Keep these values in sync
//  with the handoff when the design system changes.
//

import AppKit
import SwiftUI

// MARK: - Color tokens

extension Color {
    enum Pidgy {
        // Surfaces: 5-step neutral gray ladder, no blue tint.
        static let bg0 = Color(hex: 0x2B2B2B)
        static let bg1 = Color(hex: 0x333333)
        static let bg2 = Color(hex: 0x3A3A3A)
        static let bg3 = Color(hex: 0x424242)
        static let bg4 = Color(hex: 0x4D4D4D)

        // Foreground / text.
        static let fg1 = Color.white.opacity(0.92)
        static let fg2 = Color.white.opacity(0.62)
        static let fg3 = Color.white.opacity(0.42)
        static let fg4 = Color.white.opacity(0.26)

        // Borders / dividers.
        static let border1 = Color.white.opacity(0.06)
        static let border2 = Color.white.opacity(0.10)
        static let border3 = Color.white.opacity(0.16)
        static let divider = Color.white.opacity(0.05)

        // Accent: cool blue, used sparingly.
        static let accent = Color(hex: 0x5B8DEF)
        static let accentHover = Color(hex: 0x7AA4F4)
        static let accentPress = Color(hex: 0x4276DC)
        static let accentSoft = Color(hex: 0x5B8DEF, alpha: 0.14)
        static let accentSoftHi = Color(hex: 0x5B8DEF, alpha: 0.22)
        static let accentRing = Color(hex: 0x5B8DEF, alpha: 0.45)
        static let accentFg = Color(hex: 0xA8C2F5)

        // Semantic status.
        static let success = Color(hex: 0x5BD18B)
        static let warning = Color(hex: 0xF4B740)
        static let danger = Color(hex: 0xE5484D)
        static let info = accent

        // Avatar palette.
        static let avRed = Color(hex: 0xE04E48)
        static let avOrange = Color(hex: 0xE07B3A)
        static let avYellow = Color(hex: 0xC8A23A)
        static let avGreen = Color(hex: 0x4F9D5F)
        static let avBlue = Color(hex: 0x4A82D6)
        static let avPurple = Color(hex: 0x8E55C9)
        static let avPink = Color(hex: 0xC95590)
        static let avGraphite = Color(hex: 0x2A2B30)
    }
}

// MARK: - AppKit color bridge

extension NSColor {
    enum Pidgy {
        static let bg0 = NSColor(pidgyHex: 0x2B2B2B)
        static let bg1 = NSColor(pidgyHex: 0x333333)
        static let bg2 = NSColor(pidgyHex: 0x3A3A3A)
        static let bg3 = NSColor(pidgyHex: 0x424242)
        static let bg4 = NSColor(pidgyHex: 0x4D4D4D)

        static let accent = NSColor(pidgyHex: 0x5B8DEF)
        static let success = NSColor(pidgyHex: 0x5BD18B)
        static let warning = NSColor(pidgyHex: 0xF4B740)
        static let danger = NSColor(pidgyHex: 0xE5484D)
    }
}

// MARK: - Type ramp

extension Font {
    enum Pidgy {
        // We bundle three variable fonts. SwiftUI loads them by family name
        // (the typographic family, not the per-instance PostScript name) and
        // then applies the requested weight via `.weight(...)`. The PostScript
        // name of the bundled Newsreader is "Newsreader16pt-Regular" — using
        // it directly would give Regular only and silently fall back to Inter
        // for any "Medium" lookups. Always go through these tokens.
        private static let newsreaderFamily = "Newsreader"
        private static let interFamily = "Inter"
        private static let monoFamily = "JetBrains Mono"

        private static func newsreader(size: CGFloat) -> Font {
            Font.custom(newsreaderFamily, size: size).weight(.medium).leading(.tight)
        }

        private static func inter(size: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.custom(interFamily, size: size).weight(weight)
        }

        // ── Display (Newsreader Medium) ───────────────────────────────────────
        // Reserved for serif headlines. Sizes match the design system handoff
        // exactly — pair with -0.02em letter spacing at the call site
        // (`.tracking(-0.4)` for 22pt+, `-0.6` for 32pt, `-0.7` for 36pt).
        // Prefer the semantic aliases below.
        static let display19 = newsreader(size: 19)
        static let display22 = newsreader(size: 22)
        static let display24 = newsreader(size: 24)
        static let display26 = newsreader(size: 26)
        static let display28 = newsreader(size: 28)
        static let display32 = newsreader(size: 32)
        static let display36 = newsreader(size: 36)

        // Semantic aliases — call sites should read intent-first.
        static let brand = display19          // sidebar "Pidgy" wordmark
        static let sectionTitle = display22   // SectionHead, drawer titles, CatchMeUp hl
        static let taskDetailTitle = display24
        static let statValue = display26      // StatTile, Donut label
        static let pageTitle = display32      // Reply queue / Tasks / People / About / Pricing big values
        static let heroTitle = display36      // Dashboard "What to do now", Topic name

        // Backwards compatibility for existing call sites.
        static let displayH1 = display36
        static let displayH2 = display28

        // ── UI body (Inter) ───────────────────────────────────────────────────
        static let h2 = inter(size: 20, weight: .semibold)
        static let h3 = inter(size: 16, weight: .semibold)
        static let body = inter(size: 14)
        static let bodyMd = inter(size: 14, weight: .medium)
        static let bodySm = inter(size: 13)
        static let meta = inter(size: 11)
        static let eyebrow = inter(size: 10, weight: .semibold)

        // ── Mono (JetBrains Mono) ─────────────────────────────────────────────
        static let mono = Font.custom(monoFamily, size: 13)
        static let monoSm = Font.custom(monoFamily, size: 11)
    }
}

// MARK: - Radii

enum PidgyRadius {
    static let xs: CGFloat = 5
    static let sm: CGFloat = 7
    static let md: CGFloat = 9
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let pill: CGFloat = 999
}

// MARK: - Spacing

enum PidgySpace {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
    static let s10: CGFloat = 40
    static let s12: CGFloat = 48
    static let s16: CGFloat = 64
}

// MARK: - Motion

enum PidgyMotion {
    static let durFast: Double = 0.12
    static let durBase: Double = 0.18
    static let durSlow: Double = 0.28

    static let easeOut = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: durBase)
    static let easeOutFast = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: durFast)
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

private extension NSColor {
    convenience init(pidgyHex hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - Convenience view modifiers

extension View {
    func pidgyCard() -> some View {
        self
            .background(Color.Pidgy.bg3)
            .overlay(
                RoundedRectangle(cornerRadius: PidgyRadius.lg)
                    .stroke(Color.Pidgy.border2, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: PidgyRadius.lg))
    }

    func pidgySelectedRow() -> some View {
        self.background(Color.Pidgy.bg4)
    }

    func pidgyEyebrow() -> some View {
        self
            .font(.Pidgy.eyebrow)
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Color.Pidgy.fg3)
    }
}
