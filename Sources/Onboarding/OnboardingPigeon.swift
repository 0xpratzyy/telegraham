//
//  OnboardingPigeon.swift
//  Pidgy
//
//  The pigeon that hosts onboarding. Lives in its own click-through
//  overlay window so it can fly in from the screen edge, perch on the top
//  edge of the glass panel (overhanging it), react to what you do, and fly
//  up to the menu bar at the end. Reuses the dashboard flock's line-art
//  `PigeonMascotShape`.
//

import AppKit
import SwiftUI

@MainActor
final class PigeonActor: ObservableObject {
    @Published var center = CGPoint.zero
    @Published var size: CGFloat = 68
    @Published var wingFlap: CGFloat = 0
    @Published var showFeet = false
    @Published var opacity: Double = 0
    @Published var tilt: Double = 0          // whole-bird rotation (flight, shake)
    @Published var headDipY: CGFloat = 0     // idle peck
    @Published var headRot: Double = 0
    @Published var bob: CGFloat = 0
    @Published var hopY: CGFloat = 0
    @Published var scaleX: CGFloat = 1       // -1 = facing left
    /// True once the arrival flight has finished — the stage waits for this
    /// before showing the first line.
    @Published private(set) var hasLanded = false

    private var wingTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private(set) var perch = CGPoint.zero

    // MARK: - Flight in

    /// Glide in from off-screen right, arc above the perch, settle onto it.
    func flyIn(from start: CGPoint, to perch: CGPoint, reduceMotion: Bool) async {
        self.perch = perch
        showFeet = false
        if reduceMotion {
            center = perch
            opacity = 1
            showFeet = true
            hasLanded = true
            startIdle()
            return
        }
        center = start
        tilt = -14
        opacity = 0
        withAnimation(.easeOut(duration: 0.3)) { opacity = 1 }
        startWings(interval: 0.12)

        let above = CGPoint(x: perch.x + 26, y: perch.y - 120)
        withAnimation(.timingCurve(0.3, 0.7, 0.4, 1, duration: 1.15)) {
            center = above
            tilt = -6
        }
        try? await Task.sleep(for: .milliseconds(1150))

        // Flare and drop the last stretch, wings slower.
        startWings(interval: 0.19)
        withAnimation(.timingCurve(0.2, 0.6, 0.3, 1, duration: 0.62)) {
            center = perch
            tilt = 4
        }
        try? await Task.sleep(for: .milliseconds(560))
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
            tilt = 0
            showFeet = true
        }
        stopWings()
        hasLanded = true
        startIdle()
    }

    /// Short flight to a new spot (e.g. over to the source you picked).
    func flyTo(_ target: CGPoint, reduceMotion: Bool) async {
        guard target != perch else { return }
        perch = target
        if reduceMotion { center = target; return }
        stopIdle()
        withAnimation(.easeIn(duration: 0.14)) { showFeet = false; hopY = -8 }
        startWings(interval: 0.13)
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.timingCurve(0.35, 0.1, 0.3, 1, duration: 0.7)) {
            center = target
            hopY = 0
            tilt = target.x > center.x ? 6 : -6
        }
        try? await Task.sleep(for: .milliseconds(620))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { tilt = 0; showFeet = true }
        stopWings()
        startIdle()
    }

    // MARK: - Reactions

    /// Small delighted hop.
    func hop() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.16)) { hopY = -16 }
            try? await Task.sleep(for: .milliseconds(170))
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) { hopY = 0 }
        }
    }

    /// Head shake — "nope".
    func shake() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        Task { @MainActor in
            for deg in [-9.0, 9, -7, 6, 0] {
                withAnimation(.easeInOut(duration: 0.08)) { headRot = deg }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// Look up and away (something is happening in the browser).
    func glance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.3)) { headRot = -14; headDipY = -3 }
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeInOut(duration: 0.35)) { headRot = 0; headDipY = 0 }
        }
    }

    /// Fly up to a point (the menu bar item) and vanish into it.
    func flyOut(to target: CGPoint, reduceMotion: Bool) async {
        stopIdle()
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            return
        }
        withAnimation(.easeIn(duration: 0.18)) { showFeet = false; hopY = -10 }
        startWings(interval: 0.11)
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(.timingCurve(0.5, 0, 0.7, 0.4, duration: 1.05)) {
            center = target
            size = 18
            tilt = -18
            hopY = 0
        }
        try? await Task.sleep(for: .milliseconds(850))
        withAnimation(.easeIn(duration: 0.2)) { opacity = 0 }
        try? await Task.sleep(for: .milliseconds(200))
        stopWings()
    }

    func stopAnimations() {
        stopIdle()
        stopWings()
    }

    func resumeIdle() {
        guard hasLanded else { return }
        startIdle()
    }

    // MARK: - Loops

    private func startWings(interval: Double) {
        wingTask?.cancel()
        wingTask = Task { @MainActor in
            var up = true
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: interval)) { wingFlap = up ? 0.5 : -0.5 }
                up.toggle()
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
        }
    }

    private func stopWings() {
        wingTask?.cancel()
        wingTask = nil
        withAnimation(.easeOut(duration: 0.15)) { wingFlap = 0 }
    }

    /// Gentle bob with an occasional peck — the same shapes the dashboard
    /// flock uses, at a slower cadence.
    private func startIdle() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        idleTask?.cancel()
        withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { bob = -1.5 }
        idleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2600 + Int.random(in: 0...2200)))
                guard !Task.isCancelled else { return }
                for (dip, rot, ms) in [(6.0, 8.0, 220), (0.0, 0.0, 220), (5.0, 8.0, 180), (0.0, 0.0, 260)] {
                    withAnimation(.easeInOut(duration: Double(ms) / 1000)) {
                        headDipY = CGFloat(dip)
                        headRot = rot
                    }
                    try? await Task.sleep(for: .milliseconds(ms))
                }
            }
        }
    }

    private func stopIdle() {
        idleTask?.cancel()
        idleTask = nil
        withAnimation(.easeOut(duration: 0.2)) { bob = 0; headDipY = 0; headRot = 0 }
    }
}
