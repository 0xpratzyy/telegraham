import SwiftUI

/// The Pidgy loading indicator — the sunglasses mascot flapping its wings
/// with a gentle hover. Same 100-unit geometry as the dashboard flock
/// (DashboardPigeonFlock), simplified for small sizes and driven by a
/// TimelineView so it animates anywhere a ProgressView used to sit.
struct PidgyLoader: View {
    var size: CGFloat = 16

    private static let flapPeriod: Double = 0.55
    private static let hoverPeriod: Double = 1.2

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let flap = sin((t / Self.flapPeriod) * 2 * .pi)      // -1…1
            let hover = sin((t / Self.hoverPeriod) * 2 * .pi)    // -1…1
            Canvas { ctx, sz in
                PidgyPigeonDrawing.draw(&ctx, sz, flap: flap)
            }
            .offset(y: hover * size * 0.04)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Loading")
    }
}

enum PidgyPigeonDrawing {
    static func draw(_ ctx: inout GraphicsContext, _ sz: CGSize, flap: CGFloat) {
                let s = min(sz.width, sz.height) / 100
                let detailed = min(sz.width, sz.height) >= 34
                // Chunkier strokes at loader sizes — the mascot's 1.6-unit
                // line vanishes below ~24pt.
                let sw = max(detailed ? 2.4 * s : 4.5 * s, 0.9)
                let stroke = Color.white.opacity(0.75)
                let bodyFill = Color.Pidgy.bg1
                let lensFill = Color(white: 0.08)

                // Wings first (body covers their roots). Flap maps to the
                // flock's arrival range: folded -10° … flapped -40°.
                let rotL = Angle.degrees(-25 - 15 * flap)
                let rotR = Angle.degrees(25 + 15 * flap)
                let wingL = Path { p in
                    p.move(to: pt(24, 46, s))
                    p.addQuadCurve(to: pt(17, 60, s), control: pt(18, 50, s))
                    p.addQuadCurve(to: pt(28, 76, s), control: pt(19, 72, s))
                    p.addQuadCurve(to: pt(33, 60, s), control: pt(32, 70, s))
                    p.addQuadCurve(to: pt(24, 46, s), control: pt(32, 50, s))
                    p.closeSubpath()
                }
                let wingR = Path { p in
                    p.move(to: pt(76, 46, s))
                    p.addQuadCurve(to: pt(83, 60, s), control: pt(82, 50, s))
                    p.addQuadCurve(to: pt(72, 76, s), control: pt(81, 72, s))
                    p.addQuadCurve(to: pt(67, 60, s), control: pt(68, 70, s))
                    p.addQuadCurve(to: pt(76, 46, s), control: pt(68, 50, s))
                    p.closeSubpath()
                }
                ctx.drawLayer { layer in
                    layer.translateBy(x: 30 * s, y: 60 * s)
                    layer.rotate(by: rotL)
                    layer.translateBy(x: -30 * s, y: -60 * s)
                    layer.fill(wingL, with: .color(bodyFill))
                    layer.stroke(wingL, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))
                }
                ctx.drawLayer { layer in
                    layer.translateBy(x: 70 * s, y: 60 * s)
                    layer.rotate(by: rotR)
                    layer.translateBy(x: -70 * s, y: -60 * s)
                    layer.fill(wingR, with: .color(bodyFill))
                    layer.stroke(wingR, with: .color(stroke), style: StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round))
                }

                // Body
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

                if detailed {
                    // Belly scallops read only at bigger sizes.
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
                    }
                    ctx.stroke(feathers, with: .color(stroke.opacity(0.6)), style: StrokeStyle(lineWidth: sw * 0.6, lineCap: .round))

                    let beak = Path { p in
                        p.move(to: pt(46, 42, s))
                        p.addLine(to: pt(50, 48, s))
                        p.addLine(to: pt(54, 42, s))
                        p.closeSubpath()
                    }
                    ctx.fill(beak, with: .color(Color.white.opacity(0.08)))
                    ctx.stroke(beak, with: .color(stroke), style: StrokeStyle(lineWidth: sw * 0.8, lineCap: .round, lineJoin: .round))
                }

                // Sunglasses — the identity. Slightly oversized at small
                // sizes so they still read.
                let lensW: CGFloat = detailed ? 16 : 19
                let lensH: CGFloat = detailed ? 12 : 14
                let lensY: CGFloat = detailed ? 30 : 29
                let lensL = Path(roundedRect: CGRect(x: (50 - 3 - lensW) * s, y: lensY * s, width: lensW * s, height: lensH * s), cornerRadius: 4.5 * s)
                let lensR = Path(roundedRect: CGRect(x: (50 + 3) * s, y: lensY * s, width: lensW * s, height: lensH * s), cornerRadius: 4.5 * s)
                ctx.fill(lensL, with: .color(lensFill))
                ctx.fill(lensR, with: .color(lensFill))
                ctx.stroke(lensL, with: .color(stroke), style: StrokeStyle(lineWidth: sw * 0.8, lineJoin: .round))
                ctx.stroke(lensR, with: .color(stroke), style: StrokeStyle(lineWidth: sw * 0.8, lineJoin: .round))
                let bridge = Path { p in
                    p.move(to: pt(47, lensY + lensH / 2, s))
                    p.addLine(to: pt(53, lensY + lensH / 2, s))
                }
        ctx.stroke(bridge, with: .color(stroke), style: StrokeStyle(lineWidth: sw * 0.8, lineCap: .round))
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint {
        CGPoint(x: x * s, y: y * s)
    }
}
