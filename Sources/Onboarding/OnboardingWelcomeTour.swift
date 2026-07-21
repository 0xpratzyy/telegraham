import AppKit
import SwiftUI

// MARK: - Welcome step

struct WelcomeStep: View {
    let onNext: () -> Void

    @State private var float: CGFloat = 0
    @State private var glow: Double = 0.6

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Soft glow ring, pulsing.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0x7BA3F0).opacity(0.25), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)
                    .opacity(glow)

                PidgyMascotMark(size: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .offset(y: float)
            }
            .padding(.bottom, 28)

            Text("Welcome to Pidgy")
                .font(.Pidgy.heroTitle)
                .tracking(-1.0)
                .foregroundStyle(Color.Pidgy.fg1)
                .lineSpacing(2)

            Text("Your local-first command center for replies, tasks, people, and topics across every conversation you keep.")
                .font(.custom("Newsreader", size: 17))
                .italic()
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14)
                .frame(maxWidth: 480)

            OnboardingPrimaryButton(title: "Get started", trailingChevron: true, action: onNext)
                .padding(.top, 32)
        }
        .frame(maxWidth: 480)
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                float = -6
            }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                glow = 1.0
            }
        }
    }
}

// MARK: - Tour step

private struct TourSlide: Identifiable {
    let id = UUID()
    let eyebrow: String
    let title: String
    let body: String
    let kind: TourArtKind
}

private enum TourArtKind { case inbox, search, local }

private let tourSlides: [TourSlide] = [
    TourSlide(
        eyebrow: "Triage",
        title: "Your inbox, finally on your side",
        body: "Pidgy reads every chat in the background and decides what actually needs you. Replies, tasks, mentions — surfaced. Group spam — gone.",
        kind: .inbox
    ),
    TourSlide(
        eyebrow: "Search",
        title: "Ask in plain English",
        body: "Find the message, file, or person you need with a sentence. Pidgy reasons across all your chats and pulls the receipts.",
        kind: .search
    ),
    TourSlide(
        eyebrow: "Local",
        title: "Yours, on your machine",
        body: "Everything stays on your Mac. Your AI key, your messages, your decisions. Pidgy never phones home.",
        kind: .local
    )
]

struct TourStep: View {
    let onAdvance: () -> Void
    let onBack: () -> Void

    @State private var idx: Int = 0

    var body: some View {
        let slide = tourSlides[idx]
        VStack(spacing: 0) {
            TourArt(kind: slide.kind)
                .id(slide.id)
                .frame(maxWidth: 320, maxHeight: 160)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

            Text(slide.eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.fg3)
                .padding(.top, 26)

            Text(slide.title)
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 10)

            Text(slide.body)
                .font(.system(size: 14.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 440)

            HStack(spacing: 16) {
                circularChevronButton(symbol: "chevron.left", filled: false) {
                    if idx > 0 {
                        withAnimation(.easeOut(duration: 0.32)) { idx -= 1 }
                    } else {
                        onBack()
                    }
                }

                HStack(spacing: 6) {
                    ForEach(0..<tourSlides.count, id: \.self) { i in
                        Capsule()
                            .fill(i == idx ? Color.Pidgy.fg1 : Color.Pidgy.border2)
                            .frame(width: i == idx ? 22 : 6, height: 6)
                            .animation(.easeOut(duration: 0.28), value: idx)
                    }
                }

                circularChevronButton(symbol: "chevron.right", filled: true) {
                    if idx < tourSlides.count - 1 {
                        withAnimation(.easeOut(duration: 0.32)) { idx += 1 }
                    } else {
                        onAdvance()
                    }
                }
            }
            .padding(.top, 36)

            Button(action: onAdvance) {
                Text("Skip tour →")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .frame(maxWidth: 540)
    }

    @ViewBuilder
    private func circularChevronButton(symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? Color.Pidgy.bg1 : Color.Pidgy.fg2)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(filled ? Color.Pidgy.fg1 : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(filled ? Color.Pidgy.fg1 : Color.Pidgy.border2, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tour art (monochrome SVG-equivalent in SwiftUI)

private struct TourArt: View {
    let kind: TourArtKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x161616))
            switch kind {
            case .inbox: TourArtInbox()
            case .search: TourArtSearch()
            case .local: TourArtLocal()
            }
        }
        .frame(height: 160)
    }
}

private struct TourArtInbox: View {
    private let rows: [(icon: String, title: String, sub: String)] = [
        ("arrow.uturn.left", "Reply needed", "Direct message · 3h"),
        ("checkmark.square", "Task", "Due today"),
        ("at", "Mention", "Group chat · 1h")
    ]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.06))
                        Image(systemName: row.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xF0F0F0))
                        Text(row.sub)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

private struct TourArtSearch: View {
    private let results: [(icon: String, title: String, sub: String)] = [
        ("doc.text", "Shared file", "report-q3.pdf · last week"),
        ("text.bubble", "Group chat", "sent it over · Mon")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("where's the file from last week?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0xF0F0F0))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )

            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.06))
                        Image(systemName: r.icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xF0F0F0))
                        Text(r.sub)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private struct TourArtLocal: View {
    var body: some View {
        HStack(spacing: 26) {
            VStack(spacing: 9) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.38))
                Text("No cloud")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 46)

            VStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.82))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xF0F0F0))
                        .padding(4)
                        .background(Circle().fill(Color(hex: 0x161616)))
                        .offset(x: 5, y: 3)
                }
                Text("On your Mac")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
