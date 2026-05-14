import SwiftUI

// MARK: - DashboardPigeonFlock
//
// Native SwiftUI port of the `Pigeon.jsx` design prototype: 5 chonky
// pigeons perched on the squiggle under "What to do now". The
// squiggle is interactive — drag it down with the mouse, the pigeons
// sag along, release and they jump with feathers falling. Click any
// pigeon to shoo the whole flock; new pigeons re-arrive immediately
// after.
//
// Layout contract matches the original wrapper (`position:relative;
// height:8px`): this view occupies exactly 8pt of vertical layout
// space (same as the original `DashboardSquiggleDivider`) and the
// pigeons render OUTSIDE the bounds via overlays. Page content
// below the squiggle does not shift.
//
// The whole thing is one file because the pieces are tightly coupled
// — pull math drives both the squiggle path and each pigeon's
// Y-offset, and the per-pigeon jump animation needs to compose with
// the shared bob without inheriting it. Cohesion > splitting.

struct DashboardPigeonFlock: View {
    private static let layoutHeight: CGFloat = 8
    private static let pigeonOverflowAbove: CGFloat = 80
    private static let pigeonOverflowBelow: CGFloat = 220

    @StateObject private var flock = FlockState()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                // Z-order matters: squiggle at the bottom, then the
                // drag handle (transparent strip), then pigeons, then
                // feathers. Pigeons need to win clicks over the drag
                // handle so tapping a bird shoos rather than starts a
                // drag.
                squiggle(width: proxy.size.width)

                dragHandle(width: proxy.size.width)

                ForEach(flock.pigeons) { pigeon in
                    PigeonBirdView(
                        pigeon: pigeon,
                        containerWidth: proxy.size.width,
                        pull: flock.pull,
                        pullXVb: flock.pullXVb,
                        jumpToken: flock.jumpToken,
                        flock: flock
                    )
                    .frame(width: pigeon.size, height: pigeon.size)
                    // With .bottomLeading alignment the pigeon's frame
                    // is anchored at the bottom of the 8pt strip. The
                    // feet (94/100 of the viewBox) end ~3.4pt above
                    // that — adding a tiny +1pt y-offset matches the
                    // JSX `bottom: size*0.06 - 4 ≈ -1px` so toe tips
                    // poke a hair below the squiggle line.
                    .offset(
                        x: pigeon.leftPct * proxy.size.width - pigeon.size / 2,
                        y: 1
                    )
                    .allowsHitTesting(!pigeon.shooed)
                }

                ForEach(flock.feathers) { feather in
                    FeatherView(feather: feather, containerWidth: proxy.size.width)
                        .offset(
                            x: feather.spawnX - feather.size / 2,
                            y: -feather.spawnY
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: Self.layoutHeight, alignment: .bottomLeading)
        }
        .frame(height: Self.layoutHeight)
        // The pigeons and feathers visually extend above and below the
        // 8pt strip; `.padding(...).overlay` would force layout to
        // grow. We don't clip the ZStack so children rendering above
        // their parent frame are still drawn — the surrounding stack
        // already has plenty of vertical margin above the title.
        .accessibilityHidden(true)
    }

    private func squiggle(width: CGFloat) -> some View {
        PigeonSquiggleShape(pull: flock.pull, pullXVb: flock.pullXVb)
            .stroke(
                PidgyDashboardTheme.tertiary.opacity(0.22),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
            .frame(width: width, height: Self.layoutHeight)
    }

    private func dragHandle(width: CGFloat) -> some View {
        // Transparent strip centered on the squiggle line. JSX uses
        // `top: -4, height: 24` — strip extends 4pt above the wrapper
        // top and 12pt below the wrapper bottom, so the actual line
        // (y=4 midline of the 8pt frame) sits inside the hit area.
        // In SwiftUI bottom-leading coords this translates to a frame
        // shifted DOWN by 12pt from the default-bottom-aligned
        // position (so it spans y=-4..y=20 relative to the visible
        // strip).
        //
        // Rectangle().fill(.clear) + contentShape gives reliable hit
        // testing — a plain Color.clear or near-transparent Color is
        // sometimes treated as non-hit-testable by SwiftUI.
        //
        // .highPriorityGesture wins over the surrounding ScrollView
        // so the vertical drag isn't stolen by scroll handling on
        // first move.
        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: 32)
            .contentShape(Rectangle())
            .offset(y: 12)
            // grab (open hand) on hover; grabbing (closed hand) while
            // a drag is in flight — same as the CSS cursor: grab /
            // grabbing pair in the JSX spec.
            .pointerStyle(flock.isDragging ? .grabActive : .grabIdle)
            .highPriorityGesture(dragGesture(width: width))
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !flock.isDragging {
                    flock.beginDrag(startY: value.startLocation.y)
                }
                let pullXVb = max(0, min(1000, (value.location.x / max(1, width)) * 1000))
                let dy = value.location.y - value.startLocation.y
                flock.updateDrag(pullXVb: pullXVb, rawDy: dy)
            }
            .onEnded { _ in
                flock.endDrag(containerWidth: width)
            }
    }
}

// MARK: - Flock state coordinator

@MainActor
private final class FlockState: ObservableObject {
    @Published var pigeons: [PigeonRuntimeState]
    @Published var pull: CGFloat = 0
    @Published var pullXVb: CGFloat = 500
    @Published var jumpToken: Int = 0
    @Published var feathers: [FeatherInstance] = []
    @Published var isDragging: Bool = false

    /// Most recently shuffled settle order. Pigeons' settle delay on a
    /// release is `900ms + jumpOrder.firstIndex(of: pigeonIdx) * 220ms`,
    /// so a new shuffle each release means landing order varies.
    private(set) var jumpOrder: [Int]

    private var dragMoved: Bool = false
    private var springTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?

    init() {
        let initial = PigeonFlockProfile.flock.map { PigeonRuntimeState.make(profile: $0) }
        self.pigeons = initial
        self.jumpOrder = Array(initial.indices)
    }

    // MARK: Drag lifecycle

    func beginDrag(startY: CGFloat) {
        cancelSpring()
        dragMoved = false
        isDragging = true
        pull = 0
    }

    func updateDrag(pullXVb: CGFloat, rawDy: CGFloat) {
        self.pullXVb = pullXVb
        if abs(rawDy) > 3 { dragMoved = true }
        // Rubber-band resistance: full-strength up to ~80pt, heavy
        // damping beyond. Mirrors the JS spec exactly.
        let max: CGFloat = 80
        let pulled: CGFloat
        if rawDy <= 0 {
            pulled = 0
        } else if rawDy <= max {
            pulled = rawDy * 0.85
        } else {
            pulled = max * 0.85 + (rawDy - max) * 0.2
        }
        pull = min(120, pulled)
    }

    func endDrag(containerWidth: CGFloat) {
        let startPull = pull
        let peakX = pullXVb
        isDragging = false

        if dragMoved && startPull > 6 {
            let intensity = min(CGFloat(1), startPull / 80)
            // Shuffle settle order so pigeons don't always land left-to-right.
            var order = Array(pigeons.indices)
            order.shuffle()
            jumpOrder = order
            jumpToken &+= 1
            spawnFeathers(
                intensity: intensity,
                peakXVb: peakX,
                containerWidth: containerWidth
            )
        }

        // rAF-equivalent spring: pull * exp(-3.5 t) * cos(1.6πt), 700ms.
        runSpring(startPull: startPull)
    }

    private func runSpring(startPull: CGFloat) {
        cancelSpring()
        springTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let duration: TimeInterval = 0.7
            let start = Date()
            // ~60fps using Task.sleep — Swift Concurrency's clock is
            // monotonic so this gives smooth output.
            while !Task.isCancelled {
                let t = -start.timeIntervalSinceNow / duration
                if t >= 1 {
                    self.pull = 0
                    return
                }
                let decay = exp(-3.5 * t)
                let phase = cos(t * .pi * 1.6)
                self.pull = startPull * CGFloat(decay * phase)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func cancelSpring() {
        springTask?.cancel()
        springTask = nil
    }

    // MARK: Feathers

    private func spawnFeathers(
        intensity: CGFloat,
        peakXVb: CGFloat,
        containerWidth: CGFloat
    ) {
        var spawned: [FeatherInstance] = []
        for pigeon in pigeons {
            let env = envelopeAt(pigeon.leftPct * 1000, peakXVb)
            guard env >= 0.05 else { continue }
            let count = max(1, Int((1.0 + intensity * env * 3.0).rounded()))
            // `centerX(in: containerWidth)` returns the pigeon's
            // horizontal center in actual pt — previously we were
            // passing `1` here, so feathers spawned at x≈leftPct (a
            // fractional value <1) instead of the actual pigeon
            // position. That's why feathers piled up at the left edge.
            let pigeonCenter = pigeon.centerX(in: containerWidth)
            for _ in 0..<count {
                let offX = (CGFloat.random(in: -0.5...0.5)) * pigeon.size * 0.55
                let startBottom = pigeon.size * CGFloat.random(in: 0.2...0.8)
                let dxMag = CGFloat.random(in: 30...120)
                let dxSign: CGFloat = Bool.random() ? -1 : 1
                let dyDepth = CGFloat.random(in: 40...180)
                let rotation = Double.random(in: -1080...1080)
                let size = CGFloat.random(in: 5...14)
                let dur = TimeInterval.random(in: 1.3...3.0)
                let delay = TimeInterval.random(in: 0...0.32)
                spawned.append(FeatherInstance(
                    spawnX: pigeonCenter + offX,
                    spawnY: startBottom,
                    dx: dxMag * dxSign,
                    dy: dyDepth,
                    rotation: rotation,
                    size: size,
                    duration: dur,
                    delay: delay,
                    pigeonLeftPct: pigeon.leftPct
                ))
            }
        }
        feathers.append(contentsOf: spawned)
        // Mirror the JS 3.6s cleanup so the array doesn't grow.
        let ids = spawned.map(\.id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard let self else { return }
            self.feathers.removeAll { ids.contains($0.id) }
        }
    }

    // MARK: Shoo + re-arrival

    func shooAll() {
        guard !pigeons.contains(where: { $0.shooed }) else { return }
        var next = pigeons
        for i in next.indices { next[i].shooed = true }
        pigeons = next

        // Wait for the exit animation (~0.85s) + a beat, then re-spawn.
        rearmTask?.cancel()
        rearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            self.pigeons = PigeonFlockProfile.flock.map { PigeonRuntimeState.make(profile: $0) }
            self.jumpOrder = Array(self.pigeons.indices)
        }
    }
}

// MARK: - Profiles

private struct PigeonFlockProfile {
    let size: CGFloat
    let leftPct: CGFloat
    let action: PigeonAction

    static let flock: [PigeonFlockProfile] = [
        PigeonFlockProfile(size: 56, leftPct: 0.64, action: .peck),
        PigeonFlockProfile(size: 50, leftPct: 0.72, action: .coo),
        PigeonFlockProfile(size: 60, leftPct: 0.80, action: .chirp),
        PigeonFlockProfile(size: 52, leftPct: 0.88, action: .strut),
        PigeonFlockProfile(size: 56, leftPct: 0.95, action: .preen)
    ]
}

private enum PigeonAction: String {
    case peck, coo, chirp, strut, preen
}

private struct PigeonRuntimeState: Identifiable {
    let id = UUID()
    let size: CGFloat
    let leftPct: CGFloat
    let action: PigeonAction
    let entry: PigeonVector
    let exit: PigeonVector
    let arrivalDelay: TimeInterval
    var shooed: Bool = false

    func centerX(in containerWidth: CGFloat) -> CGFloat { leftPct * containerWidth }

    static func make(profile: PigeonFlockProfile) -> PigeonRuntimeState {
        PigeonRuntimeState(
            size: profile.size,
            leftPct: profile.leftPct,
            action: profile.action,
            entry: PigeonVector.random(),
            exit: PigeonVector.random(),
            arrivalDelay: TimeInterval.random(in: 0.3...5.0)
        )
    }
}

private struct PigeonVector {
    let dx: CGFloat
    let dy: CGFloat
    let rotation: Double

    static func random() -> PigeonVector {
        // angle 200°–340° in standard math coords (upper half-plane,
        // negative y = up). Same shape as the JS impl so visually
        // identical.
        let angleDeg = Double.random(in: 200...340)
        let dist = Double.random(in: 240...400)
        let radians = angleDeg * .pi / 180
        let dx = cos(radians) * dist
        let dy = sin(radians) * dist
        let rotation = Double.random(in: -20...20)
        return PigeonVector(dx: CGFloat(dx), dy: CGFloat(dy), rotation: rotation)
    }
}

// MARK: - Math

private let pullSigma: CGFloat = 110

private func envelopeAt(_ xVb: CGFloat, _ peakVb: CGFloat) -> CGFloat {
    let dx = xVb - peakVb
    return exp(-(dx * dx) / (2 * pullSigma * pullSigma))
}

// MARK: - Squiggle shape

private struct PigeonSquiggleShape: Shape {
    var pull: CGFloat
    var pullXVb: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pull, pullXVb) }
        set { pull = newValue.first; pullXVb = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        // 80 quadratic-curve segments across a normalized 0…1000
        // viewBox X. Y-baseline at 4 (the original 8-tall viewBox's
        // midpoint). Even-index controls are at the top of the wave
        // (y=0), odd-index at the bottom (y=8). Each control + endpoint
        // gets a Gaussian-weighted pull added so the deformation is
        // localized around the cursor.
        let segments = 80
        let vbW: CGFloat = 1000
        let vbH: CGFloat = 8
        let scaleX = rect.width / vbW
        let scaleY = rect.height / vbH

        var path = Path()
        path.move(to: CGPoint(x: 0, y: 4 * scaleY))

        for i in 0..<segments {
            let xCVb = CGFloat(i) * 12.5 + 6.25
            let xEVb = CGFloat(i + 1) * 12.5
            let yCBaseVb: CGFloat = (i % 2 == 0) ? 0 : 8
            let yEBaseVb: CGFloat = 4
            let yCVb = yCBaseVb + pull * envelopeAt(xCVb, pullXVb)
            let yEVb = yEBaseVb + pull * envelopeAt(xEVb, pullXVb)
            path.addQuadCurve(
                to: CGPoint(x: xEVb * scaleX, y: yEVb * scaleY),
                control: CGPoint(x: xCVb * scaleX, y: yCVb * scaleY)
            )
        }
        return path
    }
}

// MARK: - Pigeon bird view

/// One segment of an idle-action cycle: animate the head's translateY
/// and rotation to the target values over `duration` with easeInOut.
/// The segment list for each action mirrors the CSS keyframes 1:1.
private struct IdleSegment {
    let duration: TimeInterval
    let dipY: CGFloat
    let rotDeg: Double
}

private struct PigeonBirdView: View {
    let pigeon: PigeonRuntimeState
    let containerWidth: CGFloat
    let pull: CGFloat
    let pullXVb: CGFloat
    let jumpToken: Int
    @ObservedObject var flock: FlockState

    private enum Lifecycle { case arriving, perched, leaving, gone }
    @State private var lifecycle: Lifecycle = .arriving
    @State private var headDipY: CGFloat = 0       // idle head translateY
    @State private var headRotDeg: Double = 0      // idle head rotation
    @State private var bobOffset: CGFloat = 0
    @State private var jumpOffset: CGFloat = 0
    @State private var arriveProgress: CGFloat = 0
    @State private var leaveProgress: CGFloat = 0
    @State private var wingFlap: CGFloat = 0       // -0.5..0.5, drives wing rotation
    @State private var lastJumpToken: Int = 0
    @State private var idleTask: Task<Void, Never>?
    @State private var wingTask: Task<Void, Never>?
    @State private var chirpNoteTask: Task<Void, Never>?
    @State private var noteOpacity: Double = 0
    @State private var noteOffsetX: CGFloat = 0
    @State private var noteOffsetY: CGFloat = 0

    var body: some View {
        let isArriving = lifecycle == .arriving
        let isLeaving = lifecycle == .leaving
        let isPerched = lifecycle == .perched
        let xVb = pigeon.leftPct * 1000
        let localPull = pull * envelopeAt(xVb, pullXVb)

        let arriveOffsetX = (1 - arriveProgress) * pigeon.entry.dx
        let arriveOffsetY = (1 - arriveProgress) * pigeon.entry.dy
        let arriveRot = (1 - arriveProgress) * pigeon.entry.rotation
        let leaveOffsetX = leaveProgress * pigeon.exit.dx
        let leaveOffsetY = leaveProgress * pigeon.exit.dy
        let leaveRot = leaveProgress * pigeon.exit.rotation

        ZStack(alignment: .topTrailing) {
            // INNER: the bird shape, transformed by head-action only.
            PigeonMascotShape(showFeet: isPerched, wingFlap: wingFlap)
                .frame(width: pigeon.size, height: pigeon.size)
                .offset(y: headDipY)
                .rotationEffect(.degrees(headRotDeg), anchor: .bottom)

            // ♪ chirp note — sibling of the bird (NOT a child) so
            // the head dip doesn't carry it. Driven by its own
            // animation Task. JSX base position: top:-10, right:-6.
            // SwiftUI: position with .offset from the topTrailing
            // anchor of the ZStack.
            if pigeon.action == .chirp && isPerched {
                Text("♪")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .opacity(noteOpacity)
                    .offset(x: noteOffsetX, y: noteOffsetY)
                    .offset(x: 6, y: -10)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: pigeon.size, height: pigeon.size)
        // OUTER: bob + jump + drag pull (apply to the whole bird +
        // note pair so the note follows the bird around)
        .offset(y: jumpOffset + bobOffset + localPull)
        .offset(x: isArriving ? arriveOffsetX : (isLeaving ? leaveOffsetX : 0),
                y: isArriving ? arriveOffsetY : (isLeaving ? leaveOffsetY : 0))
        .rotationEffect(.degrees(isArriving ? arriveRot : (isLeaving ? leaveRot : 0)),
                        anchor: .bottom)
        .opacity(lifecycle == .gone ? 0 : 1)
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
        .contentShape(Rectangle())
        // The whole bird is tappable to shoo — show a pointing-hand
        // cursor so users know it's interactive.
        .pointerStyle(.link)
        .onTapGesture { flock.shooAll() }
        .onAppear { startArrival() }
        .onDisappear {
            idleTask?.cancel()
            wingTask?.cancel()
            chirpNoteTask?.cancel()
        }
        .onChange(of: pigeon.shooed) { _, shooed in
            if shooed && (lifecycle == .arriving || lifecycle == .perched) {
                startLeaving()
            }
        }
        .onChange(of: jumpToken) { _, newToken in
            guard newToken != lastJumpToken else { return }
            lastJumpToken = newToken
            startJump()
        }
    }

    // MARK: - Lifecycle

    private func startArrival() {
        arriveProgress = 0
        wingFlap = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pigeon.arrivalDelay * 1_000_000_000))
            guard lifecycle == .arriving else { return }
            withAnimation(.easeOut(duration: 1.1)) {
                arriveProgress = 1
            }
            startWingFlap()
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard lifecycle == .arriving else { return }
            lifecycle = .perched
            stopWingFlap()
            startBob()
            startIdle()
            startChirpNote()
        }
    }

    private func startLeaving() {
        lifecycle = .leaving
        leaveProgress = 0
        idleTask?.cancel()
        chirpNoteTask?.cancel()
        withAnimation(.easeIn(duration: 0.85)) {
            leaveProgress = 1
            headDipY = 0
            headRotDeg = 0
        }
        startWingFlap()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 850_000_000)
            lifecycle = .gone
            stopWingFlap()
        }
    }

    private func startBob() {
        bobOffset = 0
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            bobOffset = -1.5
        }
    }

    /// Drive the idle head action by chaining `withAnimation`
    /// segments. Each segment is monotonic (current → next), so
    /// SwiftUI interpolates them properly. After the last segment we
    /// loop back to segment 0 — which gives a continuous cycle that
    /// honours the JS keyframe shape (eg. peck dips twice per cycle).
    private func startIdle() {
        idleTask?.cancel()
        let segments = idleSegments(for: pigeon.action)
        idleTask = Task { @MainActor in
            // Initial state.
            headDipY = 0
            headRotDeg = 0
            while !Task.isCancelled && lifecycle == .perched {
                for segment in segments {
                    guard !Task.isCancelled, lifecycle == .perched else { return }
                    withAnimation(.easeInOut(duration: segment.duration)) {
                        headDipY = segment.dipY
                        headRotDeg = segment.rotDeg
                    }
                    try? await Task.sleep(nanoseconds: UInt64(segment.duration * 1_000_000_000))
                }
            }
        }
    }

    /// The ♪ chirp note's float-up-and-fade loop. Each segment maps
    /// directly to a CSS @keyframes step from `pidgy-note-float`
    /// (2.4s cycle): fade in to (2,-4) at 18%, hold to 28%, float up
    /// to (6,-14) while fading at 50%, then off-screen until next
    /// cycle. Only spawned for the chirp pigeon while it's perched.
    private func startChirpNote() {
        guard pigeon.action == .chirp else { return }
        chirpNoteTask?.cancel()
        chirpNoteTask = Task { @MainActor in
            // (duration, target opacity, target dx, target dy)
            let segs: [(d: TimeInterval, op: Double, dx: CGFloat, dy: CGFloat)] = [
                (0.432, 1, 2, -4),     // 0% → 18%: fade in to (2,-4)
                (0.168, 1, 2, -4),     // 18% → 25%: hold
                (0.168, 1, 2, -4),     // 25% → 32%: hold
                (0.672, 0, 6, -14),    // 32% → 60%: float up + fade
                (0.96,  0, 0, 0)       // 60% → 100%: reset (invisible)
            ]
            noteOpacity = 0
            noteOffsetX = 0
            noteOffsetY = 0
            while !Task.isCancelled && lifecycle == .perched {
                for seg in segs {
                    guard !Task.isCancelled, lifecycle == .perched else { return }
                    withAnimation(.easeOut(duration: seg.d)) {
                        noteOpacity = seg.op
                        noteOffsetX = seg.dx
                        noteOffsetY = seg.dy
                    }
                    try? await Task.sleep(nanoseconds: UInt64(seg.d * 1_000_000_000))
                }
            }
        }
    }

    /// Wing flap: -0.5 ↔ +0.5 oscillation at 0.22s per swing. Used
    /// during arrival and leaving. SwiftUI's repeatForever on .offset
    /// (or here, on wingFlap → Canvas read) does NOT interpolate
    /// inside Canvas, so we drive it from a Task that flips the
    /// target value every half-cycle.
    private func startWingFlap() {
        wingTask?.cancel()
        wingTask = Task { @MainActor in
            var up = true
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.11)) {
                    wingFlap = up ? 0.5 : -0.5
                }
                up.toggle()
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }

    private func stopWingFlap() {
        wingTask?.cancel()
        wingTask = nil
        withAnimation(.easeOut(duration: 0.15)) {
            wingFlap = 0
        }
    }

    private func startJump() {
        let idx = flock.jumpOrder.firstIndex(of: indexInFlock()) ?? 0
        let upMs: TimeInterval = 0.18
        let holdMs: TimeInterval = 0.9 + Double(idx) * 0.22
        let downMs: TimeInterval = 0.36
        Task { @MainActor in
            withAnimation(.easeOut(duration: upMs)) { jumpOffset = -70 }
            try? await Task.sleep(nanoseconds: UInt64((upMs + holdMs) * 1_000_000_000))
            withAnimation(.easeIn(duration: downMs)) { jumpOffset = 0 }
        }
    }

    private func indexInFlock() -> Int {
        flock.pigeons.firstIndex(where: { $0.id == pigeon.id }) ?? 0
    }

    // MARK: - Per-action idle segments (mirrors the JSX CSS keyframes)

    private func idleSegments(for action: PigeonAction) -> [IdleSegment] {
        switch action {
        case .peck:
            // 1.5s cycle. CSS: 0%/40%/100% (0,0), 55% (6, 8°), 70% (0,0), 82% (5, 8°)
            return [
                IdleSegment(duration: 0.6,   dipY: 0, rotDeg: 0),    // 0 → 40%
                IdleSegment(duration: 0.225, dipY: 6, rotDeg: 8),    // 40 → 55%
                IdleSegment(duration: 0.225, dipY: 0, rotDeg: 0),    // 55 → 70%
                IdleSegment(duration: 0.18,  dipY: 5, rotDeg: 8),    // 70 → 82%
                IdleSegment(duration: 0.27,  dipY: 0, rotDeg: 0)     // 82 → 100%
            ]
        case .coo:
            // 1.8s cycle. CSS: 0%/100% (0,0), 25% (-1, -3°), 60% (-1, 3°)
            return [
                IdleSegment(duration: 0.45, dipY: -1, rotDeg: -3),
                IdleSegment(duration: 0.63, dipY: -1, rotDeg: 3),
                IdleSegment(duration: 0.72, dipY: 0,  rotDeg: 0)
            ]
        case .chirp:
            // 2.4s cycle. CSS: 0%/60%/100% (0,0), 18%/32% (-2,-2°), 25% (-1, 2°)
            return [
                IdleSegment(duration: 0.432, dipY: -2, rotDeg: -2),
                IdleSegment(duration: 0.168, dipY: -1, rotDeg: 2),
                IdleSegment(duration: 0.168, dipY: -2, rotDeg: -2),
                IdleSegment(duration: 0.672, dipY: 0,  rotDeg: 0),
                IdleSegment(duration: 0.96,  dipY: 0,  rotDeg: 0)
            ]
        case .strut:
            // 1.1s cycle. CSS: 0%/100% (0, -1°), 50% (-1, 1°)
            return [
                IdleSegment(duration: 0.55, dipY: -1, rotDeg: 1),
                IdleSegment(duration: 0.55, dipY: 0,  rotDeg: -1)
            ]
        case .preen:
            // 2.6s cycle. CSS: 0%/40%/100% (0,0), 55%/75% (0, -22°)
            return [
                IdleSegment(duration: 1.04, dipY: 0, rotDeg: 0),
                IdleSegment(duration: 0.39, dipY: 0, rotDeg: -22),
                IdleSegment(duration: 0.52, dipY: 0, rotDeg: -22),
                IdleSegment(duration: 0.65, dipY: 0, rotDeg: 0)
            ]
        }
    }
}

// MARK: - Pigeon SVG-equivalent shape

private struct PigeonMascotShape: View {
    let showFeet: Bool
    /// 0 = wings folded, ±0.5 = wings flapped. Set by the parent
    /// during arrival/leaving via withAnimation; the wing rotation
    /// inside the Canvas is driven from this.
    let wingFlap: CGFloat

    var body: some View {
        // The Canvas drawing of the static pigeon. Idle head-action
        // movement is now applied as a SwiftUI .offset/.rotationEffect
        // by the parent via keyframeAnimator — that's the only way to
        // trace the non-monotonic peck/coo curves smoothly in SwiftUI.
        // Canvas only contains things that don't need interpolated
        // redrawing (or are driven by directly-animating parameters
        // like `wingFlap`, which is a simple ±0.5 oscillation).
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100  // 100-unit viewBox scale
            let sw: CGFloat = 1.6 * s
            let swThin: CGFloat = 1.1 * s
            let stroke = Color(white: 1.0).opacity(0.7)
            let bodyFill = Color.white.opacity(0.05)
            let wingFill = Color.white.opacity(0.04)
            let beakFill = Color.white.opacity(0.08)
            let glassesFill = Color(white: 0.1)
            let glassesHighlight = Color.white.opacity(0.55)

            // FEET — drawn first so the body covers them at base
            if showFeet {
                let feet = Path { p in
                    p.move(to: pt(40, 84, s));  p.addLine(to: pt(40, 90, s))
                    p.move(to: pt(36, 93, s));  p.addLine(to: pt(40, 90, s))
                    p.move(to: pt(40, 90, s));  p.addLine(to: pt(40, 94, s))
                    p.move(to: pt(40, 90, s));  p.addLine(to: pt(44, 93, s))

                    p.move(to: pt(60, 84, s));  p.addLine(to: pt(60, 90, s))
                    p.move(to: pt(56, 93, s));  p.addLine(to: pt(60, 90, s))
                    p.move(to: pt(60, 90, s));  p.addLine(to: pt(60, 94, s))
                    p.move(to: pt(60, 90, s));  p.addLine(to: pt(64, 93, s))
                }
                ctx.stroke(
                    feet,
                    with: .color(stroke),
                    style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round)
                )
            }

            // LEFT WING — pivots around (30, 60) in viewBox coords.
            // wingFlap ∈ [-0.5, 0.5] → rotation ∈ [-40°, +20°] per
            // the CSS keyframe spec; midline is folded at -10°.
            let wingRotL: Double = Double(-10 + wingFlap * 60)
            ctx.drawLayer { layer in
                layer.translateBy(x: 30 * s, y: 60 * s)
                layer.rotate(by: .degrees(wingRotL))
                layer.translateBy(x: -30 * s, y: -60 * s)

                let wingShape = Path { p in
                    p.move(to: pt(24, 46, s))
                    p.addQuadCurve(to: pt(17, 60, s), control: pt(18, 50, s))
                    p.addQuadCurve(to: pt(28, 76, s), control: pt(19, 72, s))
                    p.addQuadCurve(to: pt(33, 60, s), control: pt(32, 70, s))
                    p.addQuadCurve(to: pt(24, 46, s), control: pt(32, 50, s))
                    p.closeSubpath()
                }
                layer.fill(wingShape, with: .color(wingFill))
                layer.stroke(wingShape, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))

                let wingFeathers = Path { p in
                    p.move(to: pt(20, 58, s));  p.addQuadCurve(to: pt(28, 58, s), control: pt(24, 60, s))
                    p.move(to: pt(19, 64, s));  p.addQuadCurve(to: pt(29, 64, s), control: pt(24, 66, s))
                    p.move(to: pt(20, 70, s));  p.addQuadCurve(to: pt(29, 70, s), control: pt(24, 72, s))
                    p.move(to: pt(22, 75, s));  p.addQuadCurve(to: pt(28, 75, s), control: pt(25, 76.5, s))
                }
                layer.stroke(wingFeathers, with: .color(stroke), style: StrokeStyle(lineWidth: swThin, lineCap: .round))
            }

            // RIGHT WING — mirror of the left, pivots around (70, 60).
            let wingRotR: Double = Double(10 - wingFlap * 60)
            ctx.drawLayer { layer in
                layer.translateBy(x: 70 * s, y: 60 * s)
                layer.rotate(by: .degrees(wingRotR))
                layer.translateBy(x: -70 * s, y: -60 * s)

                let wingShape = Path { p in
                    p.move(to: pt(76, 46, s))
                    p.addQuadCurve(to: pt(83, 60, s), control: pt(82, 50, s))
                    p.addQuadCurve(to: pt(72, 76, s), control: pt(81, 72, s))
                    p.addQuadCurve(to: pt(67, 60, s), control: pt(68, 70, s))
                    p.addQuadCurve(to: pt(76, 46, s), control: pt(68, 50, s))
                    p.closeSubpath()
                }
                layer.fill(wingShape, with: .color(wingFill))
                layer.stroke(wingShape, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))

                let wingFeathers = Path { p in
                    p.move(to: pt(80, 58, s));  p.addQuadCurve(to: pt(72, 58, s), control: pt(76, 60, s))
                    p.move(to: pt(81, 64, s));  p.addQuadCurve(to: pt(71, 64, s), control: pt(76, 66, s))
                    p.move(to: pt(80, 70, s));  p.addQuadCurve(to: pt(71, 70, s), control: pt(76, 72, s))
                    p.move(to: pt(78, 75, s));  p.addQuadCurve(to: pt(72, 75, s), control: pt(75, 76.5, s))
                }
                layer.stroke(wingFeathers, with: .color(stroke), style: StrokeStyle(lineWidth: swThin, lineCap: .round))
            }

            // BODY — single egg-shaped silhouette with merged head.
            let body = Path { p in
                p.move(to: pt(50, 18, s))
                p.addCurve(to: pt(22, 54, s), control1: pt(30, 18, s), control2: pt(20, 34, s))
                p.addCurve(to: pt(50, 84, s), control1: pt(24, 70, s), control2: pt(34, 84, s))
                p.addCurve(to: pt(78, 54, s), control1: pt(66, 84, s), control2: pt(76, 70, s))
                p.addCurve(to: pt(50, 18, s), control1: pt(80, 34, s), control2: pt(70, 18, s))
                p.closeSubpath()
            }
            ctx.fill(body, with: .color(bodyFill))
            ctx.stroke(body, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))

            // Head/body boundary highlight
            let boundary = Path { p in
                p.move(to: pt(28, 44, s))
                p.addQuadCurve(to: pt(72, 44, s), control: pt(50, 40, s))
            }
            ctx.stroke(boundary, with: .color(stroke.opacity(0.49)), style: StrokeStyle(lineWidth: swThin, lineCap: .round))

            // Belly feather scallops — 3 rows
            let feathers = Path { p in
                p.move(to: pt(34, 56, s))
                p.addQuadCurve(to: pt(42, 56, s), control: pt(38, 60, s))
                p.addQuadCurve(to: pt(50, 56, s), control: pt(46, 60, s))
                p.addQuadCurve(to: pt(58, 56, s), control: pt(54, 60, s))
                p.addQuadCurve(to: pt(66, 56, s), control: pt(62, 60, s))

                p.move(to: pt(32, 64, s))
                p.addQuadCurve(to: pt(40, 64, s), control: pt(36, 68, s))
                p.addQuadCurve(to: pt(48, 64, s), control: pt(44, 68, s))
                p.addQuadCurve(to: pt(56, 64, s), control: pt(52, 68, s))
                p.addQuadCurve(to: pt(64, 64, s), control: pt(60, 68, s))
                p.addQuadCurve(to: pt(68, 64, s), control: pt(67, 67, s))

                p.move(to: pt(34, 72, s))
                p.addQuadCurve(to: pt(42, 72, s), control: pt(38, 76, s))
                p.addQuadCurve(to: pt(50, 72, s), control: pt(46, 76, s))
                p.addQuadCurve(to: pt(58, 72, s), control: pt(54, 76, s))
                p.addQuadCurve(to: pt(66, 72, s), control: pt(62, 76, s))
            }
            ctx.stroke(feathers, with: .color(stroke), style: StrokeStyle(lineWidth: swThin, lineCap: .round, lineJoin: .round))

            // BEAK — small triangle
            let beak = Path { p in
                p.move(to: pt(46, 42, s))
                p.addLine(to: pt(50, 48, s))
                p.addLine(to: pt(54, 42, s))
                p.closeSubpath()
            }
            ctx.fill(beak, with: .color(beakFill))
            ctx.stroke(beak, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))

            // SUNGLASSES — two black-filled rounded rects + bridge + highlights
            let leftLens = Path(roundedRect: CGRect(x: 28 * s, y: 30 * s, width: 16 * s, height: 12 * s), cornerRadius: 4 * s)
            let rightLens = Path(roundedRect: CGRect(x: 56 * s, y: 30 * s, width: 16 * s, height: 12 * s), cornerRadius: 4 * s)
            ctx.fill(leftLens, with: .color(glassesFill))
            ctx.fill(rightLens, with: .color(glassesFill))
            ctx.stroke(leftLens, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineJoin: .round))
            ctx.stroke(rightLens, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineJoin: .round))

            let bridge = Path { p in
                p.move(to: pt(44, 35, s))
                p.addLine(to: pt(56, 35, s))
            }
            ctx.stroke(bridge, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineCap: .round))

            let highlightL = Path { p in
                p.move(to: pt(32, 33, s))
                p.addLine(to: pt(35, 33, s))
            }
            let highlightR = Path { p in
                p.move(to: pt(60, 33, s))
                p.addLine(to: pt(63, 33, s))
            }
            ctx.stroke(highlightL, with: .color(glassesHighlight), style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
            ctx.stroke(highlightR, with: .color(glassesHighlight), style: StrokeStyle(lineWidth: 1.4 * s, lineCap: .round))
        }
        // The ♪ note is no longer rendered here — it would inherit
        // the head-dip transform on this view. The BirdView renders
        // it as a sibling so it can float independently.
    }
}

/// 100-unit viewBox → SwiftUI point: scale via `s`.
private func pt(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint {
    CGPoint(x: x * s, y: y * s)
}

// MARK: - Feathers

private struct FeatherInstance: Identifiable {
    let id = UUID()
    let spawnX: CGFloat
    let spawnY: CGFloat
    let dx: CGFloat
    let dy: CGFloat
    let rotation: Double
    let size: CGFloat
    let duration: TimeInterval
    let delay: TimeInterval
    let pigeonLeftPct: CGFloat
}

private struct FeatherView: View {
    let feather: FeatherInstance
    let containerWidth: CGFloat

    @State private var progress: CGFloat = 0
    @State private var opacity: Double = 0

    var body: some View {
        Path { p in
            // Leaf shape with center vein, drawn at the origin.
            let w = feather.size
            let h = feather.size * 1.6
            p.move(to: CGPoint(x: w * 0.5, y: h * 0.06))
            p.addCurve(
                to: CGPoint(x: w * 0.7, y: h * 0.84),
                control1: CGPoint(x: w * 0.85, y: h * 0.22),
                control2: CGPoint(x: w * 0.9, y: h * 0.56)
            )
            p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.94))
            p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.84))
            p.addCurve(
                to: CGPoint(x: w * 0.5, y: h * 0.06),
                control1: CGPoint(x: w * 0.1, y: h * 0.56),
                control2: CGPoint(x: w * 0.15, y: h * 0.22)
            )
            p.closeSubpath()
        }
        .fill(Color.white.opacity(0.55))
        .frame(width: feather.size, height: feather.size * 1.6)
        .rotationEffect(.degrees(feather.rotation * Double(progress)), anchor: .center)
        .offset(x: feather.dx * progress, y: feather.dy * progress)
        .opacity(opacity)
        .allowsHitTesting(false)
        .onAppear {
            // Mirror the CSS keyframe shape: fade-in over 10% of
            // duration, fade-out by 100%.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(feather.delay * 1_000_000_000))
                withAnimation(.easeIn(duration: feather.duration * 0.1)) {
                    opacity = 0.85
                }
                withAnimation(.linear(duration: feather.duration)) {
                    progress = 1
                }
                try? await Task.sleep(nanoseconds: UInt64(feather.duration * 0.9 * 1_000_000_000))
                withAnimation(.easeOut(duration: feather.duration * 0.1)) {
                    opacity = 0
                }
            }
        }
    }
}
