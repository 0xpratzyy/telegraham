//
//  OnboardingFilmView.swift
//  Pidgy
//
//  A readable brand introduction followed by a short product demo.
//  Start setup is available immediately; the demo never blocks setup.
//

import AppKit
import SwiftUI

// MARK: - Brand palette

/// Onboarding's accent set: the iridescence of a pigeon's neck against dawn
/// light. Teal for "go", violet for "chosen", peach for warmth.
enum OnboardingBrand {
    static let teal = Color(hex: 0x3DBFA6)
    static let green = Color(hex: 0x4EBE7A)
    static let violet = Color(hex: 0x8B7CF6)
    static let periwinkle = Color(hex: 0x7BA3F0)
    static let peach = Color(hex: 0xF2B98A)
}

// MARK: - Layout

/// Screen geometry every scene hangs off.
struct OnboardingLayout {
    let size: CGSize
    /// Where the flock funnels to at the end (the menu bar item), in stage
    /// coordinates. Defaults to the top-right.
    var menuBarPoint: CGPoint

    init(size: CGSize, menuBarPoint: CGPoint? = nil) {
        self.size = size
        self.menuBarPoint = menuBarPoint ?? CGPoint(x: size.width - 90, y: 12)
    }

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    // Film
    /// The parapet edge in the rooftop backdrop — the bird lands on the wall.
    var landing: CGPoint { CGPoint(x: center.x - 190, y: size.height * 0.882) }
    var pillWidth: CGFloat { min(640, size.width * 0.5) }
    var pillTop: CGFloat { size.height * 0.5 - 29 }
    var pillPerch: CGPoint { CGPoint(x: center.x - pillWidth / 2 + 44, y: pillTop + 1) }

    // Steps (float on the stage, no container)
    var columnWidth: CGFloat { max(240, min(560, size.width - 64)) }
    var columnHeight: CGFloat { min(620, max(260, size.height - 160)) }
    var columnTop: CGFloat { max(64, (size.height - columnHeight) / 2) }
    var qrSide: CGFloat { min(200, size.height * 0.28) }
    /// Top edge of the QR tile, where the bird sits while you scan. The
    /// heading is ~80pt tall at 30pt over two lines, then 26pt spacing.
    var qrPerch: CGPoint { CGPoint(x: center.x + qrSide / 2 - 30, y: columnTop + 80 + 26 + 4 + 1) }
}

// MARK: - Scene state

@MainActor
final class OnboardingSceneState: ObservableObject {
    enum Phase { case film, cards }
    @Published var phase: Phase = .film
    @Published var backdropOpacity: Double = 1
    @Published var filmStart = Date()
    /// Set when the user skips; the film view stops drawing immediately.
    @Published var filmEnded = false
}

// MARK: - Film

struct OnboardingFilmView: View {
    @ObservedObject var scene: OnboardingSceneState
    let layout: OnboardingLayout
    let onSkip: () -> Void

    static let duration: Double = 24.2

    /// One idea per vignette, ~3.6s each, the pill never leaves centre.
    struct Vignette {
        enum Kind { case replies, sources, search, tasks, summary }
        let kind: Kind
        let query: String
        let start: Double
        var typeAt: Double { start + 0.15 }
        var resultsAt: Double { start + 1.55 }
        var end: Double { start + 3.6 }
    }

    static let vignettes: [Vignette] = [
        Vignette(kind: .replies, query: "what needs a reply today?", start: 4.9),
        Vignette(kind: .search, query: "where's the invoice Akhil sent?", start: 8.5),
        Vignette(kind: .tasks, query: "what did I promise this week?", start: 12.1),
        Vignette(kind: .summary, query: "catch me up on Design", start: 15.7),
        Vignette(kind: .sources, query: "", start: 19.3)
    ]

    static func vignette(_ kind: Vignette.Kind) -> Vignette {
        vignettes.first { $0.kind == kind }!
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSince(scene.filmStart)
            ZStack(alignment: .topLeading) {
                Color.clear
                brand(t)
                launcherPill(t)
                ForEach(Array(Self.vignettes.enumerated()), id: \.offset) { _, v in
                    results(v, t)
                }
                sourceTiles(t)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .overlay(alignment: .bottomTrailing) {
            Button(action: onSkip) {
                HStack(spacing: 7) {
                    Text("Skip intro")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(12)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(24)
        }
    }

    // MARK: Curves

    private func window(_ t: Double, _ a: Double, _ b: Double, fadeIn: Double = 0.4, fadeOut: Double = 0.4) -> Double {
        guard t >= a, t <= b else { return 0 }
        let i = min(1, (t - a) / fadeIn)
        let o = min(1, (b - t) / fadeOut)
        return min(i, o)
    }

    /// 0→1 between a and b with an ease-out.
    private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let k = min(1, max(0, (t - a) / (b - a)))
        return 1 - pow(1 - k, 3)
    }

    private func typed(_ text: String, from t0: Double, at t: Double, cps: Double = 26) -> String {
        guard t >= t0 else { return "" }
        return String(text.prefix(Int((t - t0) * cps)))
    }

    // MARK: Beats

    @ViewBuilder
    private func brand(_ t: Double) -> some View {
        VStack(spacing: 12) {
            OnboardingFlock(elapsed: t, width: min(620, layout.size.width - 96))
            Text("One calm queue for everything that needs you.")
                .font(.custom("Newsreader", size: 20))
                .italic()
                .foregroundStyle(Color.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .opacity(ramp(t, 2.1, 2.8))
        }
        .frame(width: min(680, layout.size.width - 64))
        .position(x: layout.center.x, y: layout.size.height * 0.40)
        .opacity(1 - ramp(t, 4.1, 4.6))
        .allowsHitTesting(false)
    }

    private func current(_ t: Double) -> Vignette? {
        Self.vignettes.first { t >= $0.start && t < $0.end }
    }

    /// The launcher pill: appears at 4.7s and stays until the film ends.
    /// Grows into a card for the summary vignette.
    @ViewBuilder
    private func launcherPill(_ t: Double) -> some View {
        let lastEnd = Self.vignettes.last?.end ?? 20
        let show = window(t, 4.7, lastEnd + 0.6, fadeIn: 0.45, fadeOut: 0.5)
        if show > 0 {
            let v = current(t)
            let summary = Self.vignette(.summary)
            let grow = ramp(t, summary.resultsAt - 0.2, summary.resultsAt + 0.4) * (1 - ramp(t, summary.end - 0.5, summary.end))
            let height = 58 + 150 * grow
            let typedText = v.map { typed($0.query, from: $0.typeAt, at: t) } ?? ""
            let sources = Self.vignette(.sources)
            let showChipsLabel = v?.kind == .sources && t >= sources.start + 2.1

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.white.opacity(0.5))
                    if showChipsLabel {
                        Text("Telegram · Slack · Gmail · WhatsApp — read-only")
                            .foregroundStyle(Color.white.opacity(0.75))
                    } else if !typedText.isEmpty {
                        Text(typedText).foregroundStyle(Color.white)
                    } else {
                        Text("Search or ask anything…").foregroundStyle(Color.white.opacity(0.4))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(typedText.isEmpty ? 0.15 : 0.95)))
                }
                .font(.custom("Inter", size: 17))
                .padding(.horizontal, 18)
                .frame(height: 58)

                if grow > 0.05 {
                    summaryCard(t, summary)
                        .opacity(grow)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
            }
            .frame(width: layout.pillWidth, height: height, alignment: .top)
            .clipped()
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 29, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 29, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .position(x: layout.center.x + (1 - ramp(t, 4.7, 5.4)) * 90, y: layout.pillTop + height / 2)
            .opacity(show)
        }
    }

    /// Rows under the pill for replies / search / tasks.
    @ViewBuilder
    private func results(_ v: Vignette, _ t: Double) -> some View {
        if v.kind == .replies || v.kind == .search || v.kind == .tasks {
            ForEach(0..<3, id: \.self) { i in
                let a = v.resultsAt + Double(i) * 0.2
                let k = ramp(t, a, a + 0.5)
                let show = window(t, a, v.end, fadeIn: 0.3, fadeOut: 0.3)
                if show > 0 {
                    resultRow(v.kind, i, t)
                        .padding(.horizontal, 22)
                        .frame(width: layout.pillWidth, height: 52)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 22)
                        }
                        .position(x: layout.center.x - (1 - k) * 40, y: layout.pillTop + 58 + 10 + 52 * CGFloat(i) + 26)
                        .opacity(show)
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ kind: Vignette.Kind, _ i: Int, _ t: Double) -> some View {
        switch kind {
        case .replies:
            let names = ["Akhil Sharma", "Priya · #design", "Mom"]
            let previews = [
                "did you get a chance to look at the invoice?",
                "can you send the deck before Thursday's review?",
                "flight timing confirm karna, 6 baje ki hai na?"
            ]
            let meta = ["Telegram · 2h", "Slack · 5h", "WhatsApp · 1d"]
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill([Color(hex: 0x2AABEE), Color(hex: 0x611F69), Color(hex: 0x25D366)][i].opacity(0.85))
                    Text(["A", "P", "M"][i]).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(names[i]).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white)
                    Text(previews[i]).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
                }
                Spacer()
                Text(meta[i]).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.45))
            }
        case .search:
            HStack(spacing: 12) {
                Image(systemName: ["doc.text.fill", "text.bubble.fill", "number"][i])
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(["Invoice_Q3_final.pdf", "\"sent the invoice, check the attachment\"", "design › budget"][i])
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                    Text(["Akhil · Telegram · Tue", "Akhil · Telegram · Tue", "Slack · 14 messages"][i])
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer()
                Circle().fill([Color(hex: 0x2AABEE), Color(hex: 0x2AABEE), Color(hex: 0x611F69)][i]).frame(width: 7, height: 7)
            }
        case .tasks:
            // The third task ticks itself off near the end of the vignette.
            let done = i == 2 && t >= Self.vignette(.tasks).resultsAt + 1.6
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Color.white.opacity(done ? 0 : 0.45), lineWidth: 1.5)
                    if done {
                        Circle().fill(OnboardingBrand.green)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 20, height: 20)
                Text(["Send Priya the deck by Thursday", "Book the Delhi flights", "Reply to the landlord about the lease"][i])
                    .strikethrough(done, color: Color.white.opacity(0.5))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(done ? 0.45 : 1))
                Spacer()
                Text(["Thu", "Fri", "today"][i]).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.45))
            }
        default:
            EmptyView()
        }
    }

    /// Catch-me-up: the pill grows into a short summary.
    private func summaryCard(_ t: Double, _ v: Vignette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Design · this week")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.5))
            ForEach(0..<3, id: \.self) { i in
                let a = v.resultsAt + 0.2 + Double(i) * 0.18
                let k = ramp(t, a, a + 0.4)
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Color.white.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 6)
                    Text([
                        "Budget approved; Priya wants the deck before Thursday's review.",
                        "Two open threads on the icon set — Sam is waiting on you.",
                        "Launch moved to the 14th. Nobody has told marketing yet."
                    ][i])
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(k)
                .offset(x: (1 - k) * 24)
            }
        }
    }

    /// Vignette 2: the four sources rise from the bottom edge into the pill.
    @ViewBuilder
    private func sourceTiles(_ t: Double) -> some View {
        ForEach(0..<4, id: \.self) { i in
            let v = Self.vignette(.sources)
            let a = v.start + 0.5 + Double(i) * 0.22
            let k = ramp(t, a, a + 0.95)
            let show = window(t, a, v.end - 0.1, fadeIn: 0.25, fadeOut: 0.35)
            if show > 0 {
                let endX = layout.center.x - layout.pillWidth / 2 + 62 + CGFloat(i) * 30
                let endY = layout.pillTop + 29
                // Telegram from the left, Slack from the top, Gmail from the
                // right, WhatsApp from the bottom.
                let (startX, startY): (CGFloat, CGFloat) = [
                    (endX - 220, endY + 40),
                    (endX - 40, endY - 200),
                    (endX + 240, endY - 40),
                    (endX + 40, endY + 200)
                ][i]
                sourceGlyph(i)
                    .frame(width: 44 - 16 * k, height: 44 - 16 * k)
                    .clipShape(RoundedRectangle(cornerRadius: 12 - 5 * k, style: .continuous))
                    .shadow(color: .black.opacity(0.3 * (1 - k)), radius: 10, y: 6)
                    .position(x: startX + (endX - startX) * k, y: startY + (endY - startY) * k)
                    .opacity(show * (t < v.start + 2.1 ? 1 : 0))
            }
        }
    }

    @ViewBuilder
    private func sourceGlyph(_ i: Int) -> some View {
        switch i {
        case 0: BrandSVGGlyph(name: "TelegramGlyph")
        case 1: ZStack { Color.white; BrandSVGGlyph(name: "SlackGlyph", inset: 8) }
        case 2: ZStack { Color.white; BrandSVGGlyph(name: "GmailGlyph", inset: 8) }
        default:
            ZStack {
                Color(hex: 0x25D366)
                Image(systemName: "message.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Root

/// A quiet backdrop, product introduction, and setup cards.
struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingConversationModel
    @ObservedObject var scene: OnboardingSceneState
    let layout: OnboardingLayout
    let onSkip: () -> Void
    /// Click on the empty stage — step out, keep progress.
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Keep the stage quiet so the product and setup copy lead.
            ZStack {
                FrostedBackdrop()
                Color(hex: 0x070912).opacity(0.62)
            }
            .opacity(scene.backdropOpacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }

            switch scene.phase {
            case .film:
                OnboardingFilmView(scene: scene, layout: layout, onSkip: onSkip)
                    .transition(.opacity)
            case .cards:
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .opacity(scene.backdropOpacity)
                    .allowsHitTesting(false)
                OnboardingCardView(model: model, layout: layout)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }

        }
        .frame(width: layout.size.width, height: layout.size.height)
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Label("Finish later", systemImage: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .padding(12)
            }
            .buttonStyle(.plain)
            .padding(24)
            .help("Hide setup and keep your progress")
        }
        .animation(.easeInOut(duration: 0.8), value: scene.phase)
    }
}

// MARK: - Frosted backdrop

/// Behind-window blur of whatever is on screen. The stage is the desktop.
struct FrostedBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
