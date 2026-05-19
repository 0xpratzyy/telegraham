//
//  InstallWelcomeWindow.swift
//  Pidgy
//
//  First-run "Install Pidgy" welcome window — the live, in-app version of
//  the design that ships baked into the .dmg background. Reproduces the
//  drag-Pidgy-to-Applications metaphor as a brand moment: by the time
//  this window appears the user has *already* dragged the .app into
//  /Applications and launched it, so the gesture here is ceremonial.
//  Drop-on-folder fires a success overlay that segues into the existing
//  Telegram onboarding flow.
//
//  Lives in its own 720×480 NSWindow so the design specs (dark window
//  surface, illustrated wallpaper, frosted pill) don't collide with the
//  existing 680×620 OnboardingWindowController. AppDelegate gates this
//  window on `welcomeShownKey` and chains into the existing flow after
//  the user advances past the success state.
//
//  The static layer (`InstallWindowStaticBackground`) is intentionally
//  separable so the DMG-background renderer (scripts/render_install_bg)
//  can re-use exactly the same paint pipeline. That way the .dmg the
//  user sees in Finder and the first-run welcome window inside the app
//  can never visually drift.
//

import AppKit
import SwiftUI

// MARK: - Notifications

extension Foundation.Notification.Name {
    /// Posted from Preferences → About → "Replay install welcome" so a
    /// developer / tester can re-watch the brand moment without wiping
    /// the data dir. AppDelegate clears the welcomeShownKey and reopens
    /// the window from scratch.
    static let pidgyReplayInstallWelcome = Foundation.Notification.Name("pidgyReplayInstallWelcome")
}

// MARK: - Window controller

@MainActor
final class InstallWelcomeWindowController {
    private var window: NSWindow?
    private let onFinish: () -> Void

    /// `onFinish` is called whenever the welcome flow exits — whether by
    /// drop+continue (the happy path) or by the × close button. The caller
    /// is expected to flip `welcomeShownKey` and chain into the existing
    /// onboarding window.
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let buildStamp = BundledSecrets.buildCommitSHA
        let view = InstallWelcomeView(
            buildStamp: buildStamp,
            onContinue: { [weak self] in self?.dismiss() },
            onSkip: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: view)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The design has its own titlebar painted into the SwiftUI view
        // (gradient + traffic-light positions + centered title); make the
        // system titlebar transparent and slide the content under it.
        newWindow.title = "Pidgy 1.0"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.appearance = NSAppearance(named: .darkAqua)
        newWindow.isMovableByWindowBackground = true
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = hosting
        newWindow.center()
        newWindow.minSize = NSSize(width: 720, height: 480)
        newWindow.maxSize = NSSize(width: 720, height: 480)

        // The painted titlebar already includes traffic-light slots and a
        // "Pidgy 1.0 · <sha>" centered title, so hide the system buttons
        // (otherwise we'd get two sets) — except the close button which
        // the user might reach for via Cmd+W. Wire its action through
        // `dismiss()` so the welcomeShown flag still gets flipped.
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.closeButton)?.isHidden = true

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        onFinish()
    }
}

// MARK: - Root view

private struct InstallWelcomeView: View {
    let buildStamp: String?
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            InstallWindowTitlebar(buildStamp: buildStamp, onClose: onSkip)
                .frame(height: 28)

            InstallStage(onContinue: onContinue, onSkip: onSkip)
                .frame(width: 720, height: 452)
        }
        .frame(width: 720, height: 480)
        .background(Color(red: 0x1E / 255.0, green: 0x1F / 255.0, blue: 0x23 / 255.0))
        // Round the outer corners so the rest of the desktop bleeds
        // through at the same 11px radius the HTML spec uses.
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - Titlebar

private struct InstallWindowTitlebar: View {
    let buildStamp: String?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0x36 / 255.0, green: 0x37 / 255.0, blue: 0x3C / 255.0),
                    Color(red: 0x2A / 255.0, green: 0x2B / 255.0, blue: 0x2F / 255.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 8) {
                TrafficLight(color: Color(red: 0xFF / 255.0, green: 0x5F / 255.0, blue: 0x57 / 255.0), action: onClose)
                TrafficLight(color: Color(red: 0xFE / 255.0, green: 0xBC / 255.0, blue: 0x2E / 255.0), action: {})
                TrafficLight(color: Color(red: 0x28 / 255.0, green: 0xC8 / 255.0, blue: 0x40 / 255.0), action: {})
                Spacer()
            }
            .padding(.horizontal, 10)

            HStack(spacing: 6) {
                Text("Pidgy 1.0")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .tracking(0.13)
                if let buildStamp {
                    Text("· \(buildStamp)")
                        .font(.custom("JetBrains Mono", size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.36))
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(height: 0.5)
        }
    }
}

private struct TrafficLight: View {
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.5)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        .padding(0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stage (everything inside the dmg body)

private struct InstallStage: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    // The verbatim quip pools — these copy lines are part of the brand
    // and must not be edited without the design owner's nod.
    private static let friendlyQuips = [
        "psst — over here",
        "I prefer Applications, if you don't mind",
        "we're gonna be great roommates",
        "one quick drag, that's all",
        "lookin' fly today",
        "I do come with snacks"
    ]
    private static let sassyQuips = [
        "any day now…",
        "still here. still waiting.",
        "I can do this all day"
    ]
    private static let bowQuips = ["*bows*", "*coo*", "hi!", "*flap flap*", "🪶"]
    private static let failedDropQuip = "aw, so close — try again"
    private static let successLines: [(title: String, body: String)] = [
        ("Settled in.", "Pidgy is now in your Applications folder. Let's get you set up."),
        ("Made it home.", "Find Pidgy in Applications. Now let's wire it up to Telegram."),
        ("Welcome aboard.", "Pidgy is installed. Pop it open and bring on the Telegram pile.")
    ]

    // Resting centers of the two icon slots, in the stage's local
    // coordinate space (the 720×452 dmg-body area). These match the
    // icon positions baked into the .dmg's appdmg config — by keeping
    // the live welcome window and the static DMG-bg PNG anchored on
    // the same coordinates, the two experiences read identically.
    static let pidgySlotCenter = CGPoint(x: 188, y: 220)
    static let appsSlotCenter = CGPoint(x: 532, y: 220)
    private static let hotZoneRadius: CGFloat = 110
    /// Vertical offset from an icon's center to its label's center.
    /// Roughly matches Finder's icon-view label spacing for 128pt
    /// icons — the live view fakes labels itself; the DMG lets Finder
    /// draw them.
    private static let labelDownOffset: CGFloat = 82

    // MARK: drag + animation state

    @State private var iconOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var isInstalled = false
    @State private var isHot = false
    @State private var folderBouncing = false

    // Click-without-drag wiggle. Toggling the trigger restarts the
    // PhaseAnimator chain so the same view can wiggle repeatedly.
    @State private var wiggleTick = 0

    // Idle bob. Driven by a TimelineView so we don't allocate a Timer
    // and so it pauses cleanly while a drag is in flight.
    @State private var bobStarted = Date()

    // Speech bubble.
    @State private var currentQuip: String? = nil
    @State private var quipVisible = false
    @State private var quipDismissWork: DispatchWorkItem?

    // Idle tracking — drives the friendly→sassy quip pool swap.
    @State private var lastInteractionAt = Date()
    @State private var quipRotationTimer: Timer?

    // Confetti + success.
    @State private var confettiBurstID = UUID()
    @State private var showConfetti = false
    @State private var showSuccess = false
    @State private var successTitle = "Settled in."
    @State private var successBody = "Pidgy is now in your Applications folder. Let's get you set up."

    // Apps-folder dashed ring rotation (only animates when hot).
    @State private var ringRotation: Double = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Static layer — wallpaper, gradient, arrow, instruction
            // pill. Identical to the DMG background image, so what the
            // user saw in Finder when they dragged Pidgy in continues
            // here without a visual jump.
            InstallWindowStaticBackground()

            // Interactive layer
            stageContent

            // × skip button — small, top-right. The system close button
            // is hidden in the controller; this is the only escape hatch
            // from the welcome window other than completing the drop.
            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Color.black.opacity(0.32))
                    )
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.trailing, 14)
            .opacity(showSuccess ? 0 : 1)
            .accessibilityLabel("Skip welcome")
            .help("Skip welcome")

            // Confetti + success overlay sit on top of everything else.
            if showConfetti {
                ConfettiBurstView(burstID: confettiBurstID, origin: Self.appsSlotCenter)
                    .allowsHitTesting(false)
            }

            if showSuccess {
                SuccessOverlay(
                    title: successTitle,
                    copy: successBody,
                    onContinue: onContinue
                )
                .transition(.opacity)
            }
        }
        .clipped()
        .onAppear { startQuipRotation() }
        .onDisappear {
            quipRotationTimer?.invalidate()
            quipDismissWork?.cancel()
        }
    }

    // MARK: stage content

    @ViewBuilder
    private var stageContent: some View {
        // Bob amount: ±3px sine wave, 4.6s period. Paused while
        // dragging / installed so the icon doesn't drift mid-gesture.
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(bobStarted)
            let bob: CGFloat = (isDragging || isInstalled)
                ? 0
                : CGFloat(sin(elapsed * 2 * .pi / 4.6)) * 3

            ZStack(alignment: .topLeading) {
                // Pidgy slot — anchored at the resting center, with
                // drag offset + idle bob layered on top.
                ZStack {
                    PidgyAppIconView(isDragging: isDragging, wiggleTick: wiggleTick)
                        .frame(width: 128, height: 128)
                        .offset(x: iconOffset.width, y: iconOffset.height + bob)
                        .scaleEffect(isDragging ? 1.06 : 1.0)
                        .rotationEffect(.degrees(
                            isDragging
                                ? max(-6, min(6, Double(iconOffset.width) * 0.04))
                                : 0
                        ))
                        .shadow(
                            color: isDragging
                                ? Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255).opacity(0.35)
                                : .clear,
                            radius: isDragging ? 24 : 0
                        )
                        .gesture(dragGesture)
                        .opacity(isInstalled ? 0 : 1)

                    if quipVisible, let currentQuip {
                        SpeechBubble(text: currentQuip)
                            .offset(x: 60, y: -94)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .allowsHitTesting(false)
                    }
                }
                .position(x: Self.pidgySlotCenter.x, y: Self.pidgySlotCenter.y)

                Text("Pidgy")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .shadow(color: Color.black.opacity(0.7), radius: 1.5, y: 1)
                    .shadow(color: Color.black.opacity(0.5), radius: 6)
                    .position(
                        x: Self.pidgySlotCenter.x,
                        y: Self.pidgySlotCenter.y + Self.labelDownOffset
                    )
                    .opacity(isInstalled ? 0 : 1)

                // Apps folder slot — same absolute-positioning treatment.
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255)
                                .opacity(isHot ? 0.85 : 0),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                        )
                        .frame(width: 156, height: 148)
                        .rotationEffect(.degrees(isHot ? ringRotation : 0))
                        .animation(.easeOut(duration: 0.2), value: isHot)

                    ApplicationsFolderShape()
                        .frame(width: 132, height: 124)
                        .scaleEffect(isHot ? 1.06 : 1.0)
                        .offset(y: folderBouncing ? -8 : (isHot ? -4 : 0))
                        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: isHot)
                        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: folderBouncing)
                        .shadow(
                            color: isHot
                                ? Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255).opacity(0.5)
                                : .clear,
                            radius: isHot ? 14 : 0
                        )
                        .shadow(color: Color.black.opacity(0.4), radius: 12, y: 12)
                }
                .position(x: Self.appsSlotCenter.x, y: Self.appsSlotCenter.y)
                .onChange(of: isHot) { _, newValue in
                    if newValue {
                        withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                            ringRotation = 360
                        }
                    } else {
                        ringRotation = 0
                    }
                }

                Text("Applications")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .shadow(color: Color.black.opacity(0.7), radius: 1.5, y: 1)
                    .shadow(color: Color.black.opacity(0.5), radius: 6)
                    .position(
                        x: Self.appsSlotCenter.x,
                        y: Self.appsSlotCenter.y + Self.labelDownOffset
                    )
            }
            .frame(width: 720, height: 452)
        }
    }
    // ─────────────────────────────────────────────────────────────

    // MARK: - Drag gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isInstalled else { return }

                let dist = sqrt(value.translation.width * value.translation.width
                              + value.translation.height * value.translation.height)
                if dist < 4 {
                    // Below the 4pt threshold — treat as a click in flight,
                    // don't start dragging yet.
                    return
                }
                if !isDragging {
                    isDragging = true
                    hideQuip()
                }
                lastInteractionAt = Date()
                iconOffset = value.translation

                // Hot-zone test — distance from current icon center to
                // folder resting center. Matches the HTML's 110pt radius.
                let liveCenter = CGPoint(
                    x: Self.pidgySlotCenter.x + value.translation.width,
                    y: Self.pidgySlotCenter.y + value.translation.height
                )
                let dx = liveCenter.x - Self.appsSlotCenter.x
                let dy = liveCenter.y - Self.appsSlotCenter.y
                let nowHot = sqrt(dx * dx + dy * dy) < Self.hotZoneRadius
                if nowHot != isHot {
                    isHot = nowHot
                }
            }
            .onEnded { value in
                guard !isInstalled else { return }

                let dist = sqrt(value.translation.width * value.translation.width
                              + value.translation.height * value.translation.height)
                if dist < 4 {
                    // Quick click — wiggle + bow quip.
                    wiggleTick &+= 1
                    let bow = Self.bowQuips.randomElement() ?? "*coo*"
                    showQuip(bow, duration: 2.2)
                    lastInteractionAt = Date()
                    return
                }

                isDragging = false
                let liveCenter = CGPoint(
                    x: Self.pidgySlotCenter.x + value.translation.width,
                    y: Self.pidgySlotCenter.y + value.translation.height
                )
                let dx = liveCenter.x - Self.appsSlotCenter.x
                let dy = liveCenter.y - Self.appsSlotCenter.y
                if sqrt(dx * dx + dy * dy) < Self.hotZoneRadius {
                    performInstall(from: value.translation)
                } else {
                    // Snap back to resting position.
                    withAnimation(.interpolatingSpring(stiffness: 220, damping: 22)) {
                        iconOffset = .zero
                    }
                    isHot = false
                    showQuip(Self.failedDropQuip, duration: 2.6)
                }
            }
    }

    // MARK: - Install + success choreography

    private func performInstall(from translation: CGSize) {
        isInstalled = true
        isHot = false
        hideQuip()

        // Compute the exact translation that lands the icon center on
        // the folder center, then animate icon shrinking + fading into it.
        let target = CGSize(
            width: Self.appsSlotCenter.x - Self.pidgySlotCenter.x,
            height: Self.appsSlotCenter.y - Self.pidgySlotCenter.y
        )
        withAnimation(.easeIn(duration: 0.46)) {
            iconOffset = target
        }

        // Folder bounce + confetti, ~380ms after the icon starts moving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                folderBouncing = true
            }
            confettiBurstID = UUID()
            showConfetti = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeOut(duration: 0.25)) {
                    folderBouncing = false
                }
            }
        }

        // Success overlay fades in ~760ms after the install begins, to
        // let the confetti play first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.76) {
            let pick = Self.successLines.randomElement() ?? Self.successLines[0]
            successTitle = pick.title
            successBody = pick.body
            withAnimation(.easeInOut(duration: 0.32)) {
                showSuccess = true
            }
        }

        // Stop the confetti elements after their natural ~1.5s lifetime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            showConfetti = false
        }
    }

    // MARK: - Quips

    private func startQuipRotation() {
        // Friendly greeting after a brief beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            showQuip(Self.friendlyQuips[0], duration: 3.2)
        }
        quipRotationTimer = Timer.scheduledTimer(withTimeInterval: 6.8, repeats: true) { _ in
            Task { @MainActor in
                guard !isDragging, !isInstalled else { return }
                let idle = Date().timeIntervalSince(lastInteractionAt)
                let pool: [String] = idle > 18 ? Self.sassyQuips : Self.friendlyQuips
                if let quip = pool.randomElement() {
                    showQuip(quip, duration: 3.2)
                }
            }
        }
    }

    private func showQuip(_ text: String, duration: TimeInterval) {
        guard !isInstalled else { return }
        quipDismissWork?.cancel()
        currentQuip = text
        withAnimation(.easeOut(duration: 0.26)) {
            quipVisible = true
        }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.26)) {
                quipVisible = false
            }
        }
        quipDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hideQuip() {
        quipDismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            quipVisible = false
        }
    }
}

// MARK: - Static background (shared with the DMG-bg renderer)

/// The wallpaper + gradient overlay + arrow + instruction pill, with
/// no interactive elements layered on top. Intentionally separable so
/// `scripts/render_install_bg` can render this exact view to a flat
/// 720×480 PNG for the DMG background — the icons that Finder draws
/// over the DMG window land in the empty slot positions below.
struct InstallWindowStaticBackground: View {
    var body: some View {
        ZStack {
            // Wallpaper — cover-fit, with a vertical gradient overlay
            // that darkens the bottom 35% so the instruction stays
            // legible without hiding the artwork.
            Image("InstallWallpaper")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 720, height: 452)
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.05), location: 0),
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.35), location: 0.65),
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.78), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Dashed marching-ants arrow, anchored between the two
            // icon resting centers (188, 220) and (532, 220). Width
            // 216 covers the gap edge-to-edge; height 80 leaves room
            // for the curve.
            DashedArrow()
                .frame(width: 216, height: 80)
                .position(x: 360, y: 220)
                .allowsHitTesting(false)

            // Frosted-glass instruction pill, anchored at the bottom.
            VStack {
                Spacer()
                InstructionPill()
                    .padding(.bottom, 22)
            }
        }
        .frame(width: 720, height: 452)
        .background(Color(red: 0x1A / 255.0, green: 0x2A / 255.0, blue: 0x3F / 255.0))
    }
}

// MARK: - Dashed arrow

private struct DashedArrow: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                // Period 1.8s, total dash run = dashWidth+gap = 9+10 = 19.
                let t = timeline.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.8) / 1.8
                let phase = -t * 19.0

                let path = arrowPath(in: size)
                let head = arrowHead(in: size)

                // Blue glow underlay (the white stroke would otherwise
                // dissolve into the bright sky region of the wallpaper).
                let glow = Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255).opacity(0.45)
                context.addFilter(.blur(radius: 4))
                context.stroke(
                    path,
                    with: .color(glow),
                    style: StrokeStyle(lineWidth: 6.5, lineCap: .round, dash: [9, 10], dashPhase: phase)
                )
                context.stroke(
                    head,
                    with: .color(glow),
                    style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round)
                )

                // White marching-ants stroke on top.
                let main = GraphicsContext.Shading.color(.white.opacity(0.95))
                var sharp = context
                sharp.addFilter(.shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1))
                sharp.stroke(
                    path,
                    with: main,
                    style: StrokeStyle(lineWidth: 3.6, lineCap: .round, dash: [9, 10], dashPhase: phase)
                )
                sharp.stroke(
                    head,
                    with: main,
                    style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private func arrowPath(in size: CGSize) -> Path {
        // Quadratic curve mirroring the HTML's M 10 40 Q 140 8 250 40
        // in a 280×80 viewbox, normalized to the available size.
        Path { path in
            let sx = size.width / 280.0
            let sy = size.height / 80.0
            path.move(to: CGPoint(x: 10 * sx, y: 40 * sy))
            path.addQuadCurve(
                to: CGPoint(x: 250 * sx, y: 40 * sy),
                control: CGPoint(x: 140 * sx, y: 8 * sy)
            )
        }
    }

    private func arrowHead(in size: CGSize) -> Path {
        Path { path in
            let sx = size.width / 280.0
            let sy = size.height / 80.0
            path.move(to: CGPoint(x: 238 * sx, y: 30 * sy))
            path.addLine(to: CGPoint(x: 252 * sx, y: 40 * sy))
            path.addLine(to: CGPoint(x: 238 * sx, y: 50 * sy))
        }
    }
}

// MARK: - Instruction pill

private struct InstructionPill: View {
    var body: some View {
        // Single Text via `+` concatenation so the spaces stay
        // part of a single run — the previous HStack(spacing: 4)
        // + Text-per-fragment layout double-spaced around every
        // bold word.
        (
            Text("To install Pidgy, drag ")
                .foregroundColor(Color.white.opacity(0.96))
            + Text("Pidgy").bold().foregroundColor(.white)
            + Text(" to your ").foregroundColor(Color.white.opacity(0.96))
            + Text("Applications").bold().foregroundColor(.white)
            + Text(" folder").foregroundColor(Color.white.opacity(0.96))
        )
        .font(.system(size: 13, weight: .medium))
        .tracking(-0.07)
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Color.black.opacity(0.30))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

// MARK: - Pidgy app icon view (dark gradient shell + mascot)

private struct PidgyAppIconView: View {
    let isDragging: Bool
    let wiggleTick: Int

    @State private var wigglePhase: Int = 0
    @State private var wiggleTask: Task<Void, Never>?

    var body: some View {
        // The shell. The mascot photo is layered inside; an outer
        // highlight gradient mimics the macOS Big Sur icon vignette.
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0x4A / 255, green: 0x4B / 255, blue: 0x52 / 255),
                            Color(red: 0x2E / 255, green: 0x2F / 255, blue: 0x34 / 255),
                            Color(red: 0x1E / 255, green: 0x1F / 255, blue: 0x23 / 255)
                        ],
                        center: UnitPoint(x: 0.3, y: 0.2),
                        startRadius: 5,
                        endRadius: 140
                    )
                )

            Image("PidgyMascotPhoto")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 148, height: 148)
                .offset(y: 8) // matches CSS `object-position: center 30%`
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            // Top highlight + bottom shade vignette.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.18), location: 0),
                            .init(color: .white.opacity(0), location: 0.24),
                            .init(color: .white.opacity(0), location: 0.72),
                            .init(color: .black.opacity(0.15), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        // Inset/outset shadows blended to taste — the design calls for
        // a heavy outer drop shadow when at rest, a brighter ring when
        // dragging (the latter is applied at the slot level).
        .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
        .shadow(color: .black.opacity(0.55), radius: 18, y: 16)
        .rotationEffect(.degrees(wiggleAngle(for: wigglePhase)))
        .scaleEffect(wiggleScale(for: wigglePhase))
        .onChange(of: wiggleTick) { _, _ in playWiggle() }
    }

    // Approximation of the CSS @keyframes wiggle — discrete frames at
    // 0/15/35/55/75/100 % over 540ms. SwiftUI doesn't expose keyframe
    // values across @State the way Swift Charts does, so we drive a
    // small Task that bumps the phase.
    private func playWiggle() {
        wiggleTask?.cancel()
        wiggleTask = Task { @MainActor in
            let frames: [(Int, Double)] = [(1, 0.08), (2, 0.10), (3, 0.10), (4, 0.10), (5, 0.10), (0, 0.10)]
            for (phase, delay) in frames {
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: delay * 0.9)) {
                    wigglePhase = phase
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            withAnimation(.easeOut(duration: 0.1)) {
                wigglePhase = 0
            }
        }
    }

    private func wiggleAngle(for phase: Int) -> Double {
        switch phase {
        case 1: return -6
        case 2: return 5
        case 3: return -3
        case 4: return 2
        default: return 0
        }
    }

    private func wiggleScale(for phase: Int) -> CGFloat {
        switch phase {
        case 1, 2: return 1.04
        case 3, 4: return 1.02
        default: return 1.0
        }
    }
}

// MARK: - Applications folder

private struct ApplicationsFolderShape: View {
    var body: some View {
        ZStack {
            // Back tab — darker gradient.
            FolderBackPath()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0x5C / 255, green: 0x8F / 255, blue: 0xE5 / 255),
                            Color(red: 0x30 / 255, green: 0x68 / 255, blue: 0xD6 / 255)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    FolderBackPath().stroke(Color.black.opacity(0.15), lineWidth: 0.5)
                )

            // Front pocket — lighter gradient.
            FolderFrontPath()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0x9C / 255, green: 0xC0 / 255, blue: 0xF5 / 255), location: 0),
                            .init(color: Color(red: 0x7B / 255, green: 0xA3 / 255, blue: 0xF0 / 255), location: 0.5),
                            .init(color: Color(red: 0x5C / 255, green: 0x8F / 255, blue: 0xE5 / 255), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    FolderFrontPath().stroke(Color.black.opacity(0.15), lineWidth: 0.5)
                )

            // Top highlight band on the front pocket.
            Path { path in
                path.move(to: CGPoint(x: 2, y: 42))
                path.addLine(to: CGPoint(x: 130, y: 42))
                path.addLine(to: CGPoint(x: 130, y: 46))
                path.addLine(to: CGPoint(x: 2, y: 46))
                path.closeSubpath()
            }
            .fill(Color.white.opacity(0.4))

            // Letter "A" — two slanted strokes + a crossbar.
            Path { path in
                path.move(to: CGPoint(x: 50, y: 94))
                path.addLine(to: CGPoint(x: 66, y: 62))
                path.addLine(to: CGPoint(x: 82, y: 94))
                path.move(to: CGPoint(x: 56, y: 86))
                path.addLine(to: CGPoint(x: 76, y: 86))
            }
            .stroke(
                Color.white.opacity(0.85),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 132, height: 124)
    }
}

private struct FolderBackPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Re-scale 132×124 source coords into rect.
        let sx = rect.width / 132
        let sy = rect.height / 124
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * sx + rect.minX, y: y * sy + rect.minY)
        }
        path.move(to: p(2, 24))
        path.addQuadCurve(to: p(14, 14), control: p(2, 14))
        path.addLine(to: p(52, 14))
        path.addLine(to: p(66, 28))
        path.addLine(to: p(118, 28))
        path.addQuadCurve(to: p(130, 38), control: p(130, 28))
        path.addLine(to: p(130, 50))
        path.addLine(to: p(2, 50))
        path.closeSubpath()
        return path
    }
}

private struct FolderFrontPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 132
        let sy = rect.height / 124
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * sx + rect.minX, y: y * sy + rect.minY)
        }
        path.move(to: p(2, 42))
        path.addLine(to: p(130, 42))
        path.addLine(to: p(130, 108))
        path.addQuadCurve(to: p(118, 118), control: p(130, 118))
        path.addLine(to: p(14, 118))
        path.addQuadCurve(to: p(2, 108), control: p(2, 118))
        path.closeSubpath()
        return path
    }
}

// MARK: - Speech bubble

private struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color(red: 0x1A / 255, green: 0x1B / 255, blue: 0x1F / 255))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0xF4 / 255, green: 0xEF / 255, blue: 0xE4 / 255))

                    // Tail — small rotated square, 18px from the leading
                    // edge, peeking out the bottom.
                    Rectangle()
                        .fill(Color(red: 0xF4 / 255, green: 0xEF / 255, blue: 0xE4 / 255))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(45))
                        .offset(x: 14, y: 5)
                }
            )
            .overlay(
                // Soft inner-stroke for the bubble.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 10, y: 10)
            .fixedSize()
    }
}

// MARK: - Confetti burst

private struct ConfettiBurstView: View {
    let burstID: UUID
    let origin: CGPoint

    // Verbatim from the design: blue, light blue, gold, cream, green.
    private static let featherColors: [Color] = [
        Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255),
        Color(red: 0xA8 / 255, green: 0xC2 / 255, blue: 0xF5 / 255),
        Color(red: 0xE0 / 255, green: 0xA3 / 255, blue: 0x6A / 255),
        Color(red: 0xF5 / 255, green: 0xEF / 255, blue: 0xE0 / 255),
        Color(red: 0x5B / 255, green: 0xD1 / 255, blue: 0x8B / 255)
    ]

    private struct Feather: Identifiable {
        let id = UUID()
        let color: Color
        let angle: Double
        let distance: CGFloat
        let rotation: Double
        let lifetime: Double
    }

    @State private var feathers: [Feather] = []
    @State private var animated = false

    var body: some View {
        ZStack {
            ForEach(feathers) { feather in
                Capsule()
                    .fill(feather.color)
                    .frame(width: 14, height: 4)
                    .rotationEffect(.degrees(animated ? feather.rotation : 0))
                    .offset(
                        x: animated ? cos(feather.angle) * feather.distance : 0,
                        y: animated ? (sin(feather.angle) * feather.distance + 70) : 0
                    )
                    .opacity(animated ? 0 : 1)
                    .position(origin)
                    .animation(
                        .timingCurve(0.2, 0.6, 0.2, 1, duration: feather.lifetime),
                        value: animated
                    )
            }
        }
        .onAppear { spawn() }
        .onChange(of: burstID) { _, _ in spawn() }
    }

    private func spawn() {
        feathers = (0..<14).map { i in
            let angle = (Double(i) / 14.0) * .pi * 2 + Double.random(in: -0.2...0.2)
            return Feather(
                color: Self.featherColors[i % Self.featherColors.count],
                angle: angle,
                distance: CGFloat.random(in: 60...120),
                rotation: Double.random(in: -360...360),
                lifetime: Double.random(in: 1.1...1.5)
            )
        }
        animated = false
        DispatchQueue.main.async {
            animated = true
        }
    }
}

// MARK: - Success overlay

private struct SuccessOverlay: View {
    let title: String
    let copy: String
    let onContinue: () -> Void

    @State private var checkScale: CGFloat = 0.6
    @State private var checkOpacity: Double = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1A / 255).opacity(0.88),
                    Color(red: 0x10 / 255, green: 0x11 / 255, blue: 0x14 / 255).opacity(0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial)

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0x5B / 255, green: 0xD1 / 255, blue: 0x8B / 255))
                        .frame(width: 84, height: 84)
                        .shadow(color: Color(red: 0x5B / 255, green: 0xD1 / 255, blue: 0x8B / 255).opacity(0.55),
                                radius: 16, y: 12)
                        .shadow(color: Color(red: 0x5B / 255, green: 0xD1 / 255, blue: 0x8B / 255).opacity(0.25),
                                radius: 30)

                    Path { path in
                        // Polyline 5,12 → 10,17 → 19,8 in a 24x24 viewbox.
                        path.move(to: CGPoint(x: 12.5, y: 27))
                        path.addLine(to: CGPoint(x: 22, y: 38))
                        path.addLine(to: CGPoint(x: 41, y: 18))
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: 56, height: 56)
                }
                .scaleEffect(checkScale)
                .opacity(checkOpacity)

                VStack(spacing: 10) {
                    Text(title)
                        .font(.custom("Newsreader", size: 32))
                        .fontWeight(.medium)
                        .tracking(-0.7)
                        .foregroundStyle(Color.white.opacity(0.94))

                    Text(copy)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 360)
                }
                .opacity(contentOpacity)

                Button(action: onContinue) {
                    HStack(spacing: 6) {
                        Text("Continue").fontWeight(.semibold)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(
                        Capsule().fill(Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255))
                    )
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255).opacity(0.4),
                            radius: 14, y: 8)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .opacity(contentOpacity)
            }
            .padding(.bottom, 12)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                checkScale = 1.0
                checkOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.18)) {
                contentOpacity = 1.0
            }
        }
    }
}
