// The original flock-to-wordmark beat, with deterministic paths and a crisp
// typographic landing. Decoration never carries the only readable label.

import AppKit
import SwiftUI

struct OnboardingFlock: View {
    let elapsed: Double
    let width: CGFloat

    var body: some View {
        ZStack {
            if elapsed < 3.6 {
                Canvas { context, size in
                    let targets = FlockWordmark.targets
                    for (index, target) in targets.enumerated() {
                        let delay = Double(index % 8) * 0.045
                        let progress = smooth(elapsed, delay, 1.8 + delay)
                        let destination = CGPoint(x: size.width / 2 + target.x * width,
                                                  y: size.height / 2 + target.y * width)
                        let start = CGPoint(x: -35 - CGFloat(index % 6) * 25,
                                            y: size.height * 0.35 + CGFloat(index % 9) * 9)
                        let x = start.x + (destination.x - start.x) * progress
                        let y = start.y + (destination.y - start.y) * progress - sin(progress * .pi) * 30
                        let fade = smooth(elapsed, delay, delay + 0.3) * (1 - smooth(elapsed, 2.0, 3.4))
                        guard fade > 0, x > 0 else { continue }
                        var bird = context
                        bird.translateBy(x: x, y: y)
                        let scale = 0.40 + 0.10 * Double(index % 3)
                        bird.scaleBy(x: scale, y: scale)
                        bird.rotate(by: .degrees(-8 * (1 - progress)))
                        let tint: Color = index % 13 == 0 ? Color(hex: 0x8DDAC9) : .white
                        bird.fill(FlockWordmark.bird(wing: sin(elapsed * 7 + Double(index))),
                                  with: .color(tint.opacity(fade * 0.8)))
                    }
                }
            }
            Text("Pidgy")
                .font(.custom("Newsreader", size: width * 0.30))
                .tracking(-width * 0.008)
                .foregroundStyle(.white)
                .opacity(smooth(elapsed, 1.1, 2.5))
                .scaleEffect(0.985 + 0.015 * smooth(elapsed, 1.1, 2.5))
        }
        .frame(width: width, height: width * 0.36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pidgy")
        .allowsHitTesting(false)
    }

    private func smooth(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let p = min(1, max(0, (t - a) / (b - a)))
        return p * p * (3 - 2 * p)
    }
}

@MainActor
private enum FlockWordmark {
    static let targets: [CGPoint] = {
        let font = NSFont(name: "NewsreaderRoman-Regular", size: 150) ?? NSFont.systemFont(ofSize: 150)
        let text = NSAttributedString(string: "Pidgy", attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        let w = Int(ceil(size.width)) + 8, h = Int(ceil(size.height)) + 8
        guard let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        text.draw(at: CGPoint(x: 4, y: 4))
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var points: [CGPoint] = []
        for x in stride(from: 0, to: w, by: 3) {
            for y in stride(from: 0, to: h, by: 3) where bytes[y * w + x] > 110 {
                points.append(CGPoint(x: (CGFloat(x) - size.width / 2 - 4) / 500,
                                      y: (size.height / 2 - CGFloat(y) + 4) / 500))
            }
        }
        guard !points.isEmpty else { return [] }
        return (0..<56).map { points[$0 * points.count / 56] }
    }()

    static func bird(wing: Double) -> Path {
        let tip = -10 - wing * 2
        var p = Path()
        p.move(to: CGPoint(x: 10, y: -1))
        p.addLine(to: CGPoint(x: 14, y: 1))
        p.addLine(to: CGPoint(x: 10, y: 2))
        p.addQuadCurve(to: CGPoint(x: 2, y: 6), control: CGPoint(x: 8, y: 7))
        p.addLine(to: CGPoint(x: -11, y: 7))
        p.addLine(to: CGPoint(x: -6, y: 3))
        p.addQuadCurve(to: CGPoint(x: -11, y: tip), control: CGPoint(x: -6, y: -2))
        p.addQuadCurve(to: CGPoint(x: 1, y: -3), control: CGPoint(x: -3, y: tip + 1))
        p.addLine(to: CGPoint(x: 5, y: tip - 2))
        p.addQuadCurve(to: CGPoint(x: 7, y: -3), control: CGPoint(x: 8, y: tip + 3))
        p.addQuadCurve(to: CGPoint(x: 10, y: -1), control: CGPoint(x: 10, y: -5))
        p.closeSubpath()
        return p
    }
}
