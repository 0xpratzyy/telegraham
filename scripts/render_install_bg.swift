#!/usr/bin/env swift

//
//  scripts/render_install_bg.swift
//
//  Bakes the static, no-personality version of the Install Pidgy
//  design into a flat 720×452 PNG used as the .dmg window background.
//
//  - Reads:
//      Sources/Resources/Assets.xcassets/InstallWallpaper.imageset/install-wallpaper.png
//      Sources/Resources/Assets.xcassets/PidgyMascotPhoto.imageset/pidgy-mascot.png
//  - Writes:
//      dist/install-bg.png   (default — override via --output PATH)
//
//  The painting code here intentionally mirrors
//  `InstallWindowStaticBackground` in
//  `Sources/Onboarding/InstallWelcomeWindow.swift` — when colors,
//  positions, or copy change there, change them here too. Verbatim
//  duplication is the price of being able to render the background
//  outside the app's compiled bundle.
//
//  Run:
//      swift scripts/render_install_bg.swift
//      swift scripts/render_install_bg.swift --output /tmp/install-bg.png
//

import AppKit
import SwiftUI

// MARK: - Argument parsing

struct Options {
    var outputPath: String = "dist/install-bg.png"
    var scale: CGFloat = 2.0
}

func parseArgs() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--output", "-o":
            guard !args.isEmpty else {
                FileHandle.standardError.write(Data("error: --output expects a path\n".utf8))
                exit(2)
            }
            opts.outputPath = args.removeFirst()
        case "--scale":
            guard let next = args.first, let s = Double(next) else {
                FileHandle.standardError.write(Data("error: --scale expects a number\n".utf8))
                exit(2)
            }
            opts.scale = CGFloat(s)
            args.removeFirst()
        case "-h", "--help":
            print("""
            Usage: swift scripts/render_install_bg.swift [--output PATH] [--scale N]

            Renders the static install-window background PNG (default
            720×452 @ 2x = 1440×904) into PATH (default dist/install-bg.png).
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("error: unknown flag \(arg)\n".utf8))
            exit(2)
        }
    }
    return opts
}

// MARK: - The view

@available(macOS 13.0, *)
struct StaticInstallBackground: View {
    let wallpaper: NSImage
    let mascot: NSImage

    var body: some View {
        ZStack {
            Image(nsImage: wallpaper)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 720, height: 452)
                .clipped()

            // Bottom-darkening gradient. Two design jobs in one:
            //   1. Keep the instruction pill legible at the very
            //      bottom.
            //   2. Make the strip behind the Finder labels (y ≈ 290
            //      in stage coords, about 64% of the 452pt height)
            //      dark enough that macOS auto-picks WHITE text for
            //      the labels — there's no AppleScript hook to set
            //      the label colour directly, so wallpaper luminance
            //      is the lever. The previous 3-stop gradient only
            //      reached 0.35 opacity by y=290 and labels rendered
            //      black against the bright sky.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.02), location: 0),
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.12), location: 0.40),
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.60), location: 0.62),
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.78), location: 0.78),
                    .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.88), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Static dashed arrow at dashPhase 0 — the marching-ants
            // motion is the live-view bonus; in a baked PNG the arrow
            // is a single frame.
            StaticDashedArrow()
                .frame(width: 216, height: 80)
                .position(x: 360, y: 220)

            // Frosted-glass instruction pill, anchored bottom-center.
            VStack {
                Spacer()
                StaticInstructionPill()
                    .padding(.bottom, 22)
            }
        }
        .frame(width: 720, height: 452)
        .background(Color(red: 0x1A / 255.0, green: 0x2A / 255.0, blue: 0x3F / 255.0))
    }
}

@available(macOS 13.0, *)
struct StaticDashedArrow: View {
    var body: some View {
        Canvas { context, size in
            let sx = size.width / 280.0
            let sy = size.height / 80.0

            var path = Path()
            path.move(to: CGPoint(x: 10 * sx, y: 40 * sy))
            path.addQuadCurve(
                to: CGPoint(x: 250 * sx, y: 40 * sy),
                control: CGPoint(x: 140 * sx, y: 8 * sy)
            )

            var head = Path()
            head.move(to: CGPoint(x: 238 * sx, y: 30 * sy))
            head.addLine(to: CGPoint(x: 252 * sx, y: 40 * sy))
            head.addLine(to: CGPoint(x: 238 * sx, y: 50 * sy))

            let glow = Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255).opacity(0.45)
            var glowCtx = context
            glowCtx.addFilter(.blur(radius: 4))
            glowCtx.stroke(
                path,
                with: .color(glow),
                style: StrokeStyle(lineWidth: 6.5, lineCap: .round, dash: [9, 10])
            )
            glowCtx.stroke(
                head,
                with: .color(glow),
                style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round)
            )

            var sharp = context
            sharp.addFilter(.shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 1))
            sharp.stroke(
                path,
                with: .color(.white.opacity(0.95)),
                style: StrokeStyle(lineWidth: 3.6, lineCap: .round, dash: [9, 10])
            )
            sharp.stroke(
                head,
                with: .color(.white.opacity(0.95)),
                style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

@available(macOS 13.0, *)
struct StaticInstructionPill: View {
    var body: some View {
        // Single Text with `+` concatenation so the spaces around
        // "Pidgy" and "Applications" are part of a single string
        // run — no HStack spacing, no per-fragment kerning drift.
        // The previous HStack(spacing: 4) + Text-per-fragment
        // layout double-spaced around every bold word.
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
        // The live window uses `.ultraThinMaterial` for a real
        // backdrop blur; ImageRenderer can't actually run the system
        // blur (it has no backdrop), so we fall back to a flat dark
        // pill that reads cleanly against the wallpaper.
        .background(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(Color.black.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

// MARK: - Top-level (script entry point)
//
// ImageRenderer is @MainActor-isolated. Script-mode Swift runs the
// top-level code synchronously on the main *thread* but with no
// declared actor context, so we wrap the body in
// `MainActor.assumeIsolated` to hop into the right isolation
// without spinning up a runloop / async wrapper.

@available(macOS 13.0, *)
@MainActor
func renderInstallBackground() throws {
    let opts = parseArgs()

    // Resolve the project root from the script's own location so the
    // script works whether invoked from the repo root, from `dist/`,
    // or from a build directory. `CommandLine.arguments[0]` is the
    // path the user passed to `swift`.
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    let projectRoot: URL = {
        let sd = scriptURL.deletingLastPathComponent()
        // scripts/ lives at repo root, so the parent of that is the
        // project root.
        if sd.lastPathComponent == "scripts" {
            return sd.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    let wallpaperURL = projectRoot.appendingPathComponent(
        "Sources/Resources/Assets.xcassets/InstallWallpaper.imageset/install-wallpaper.png"
    )
    let mascotURL = projectRoot.appendingPathComponent(
        "Sources/Resources/Assets.xcassets/PidgyMascotPhoto.imageset/pidgy-mascot.png"
    )
    guard let wallpaper = NSImage(contentsOf: wallpaperURL) else {
        FileHandle.standardError.write(Data("error: cannot read wallpaper at \(wallpaperURL.path)\n".utf8))
        exit(1)
    }
    guard let mascot = NSImage(contentsOf: mascotURL) else {
        FileHandle.standardError.write(Data("error: cannot read mascot at \(mascotURL.path)\n".utf8))
        exit(1)
    }

    let outputURL: URL = {
        let raw = opts.outputPath
        if (raw as NSString).isAbsolutePath {
            return URL(fileURLWithPath: raw)
        }
        return URL(fileURLWithPath: raw, relativeTo: projectRoot)
    }()
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let view = StaticInstallBackground(wallpaper: wallpaper, mascot: mascot)
    let renderer = ImageRenderer(content: view)
    renderer.scale = opts.scale
    // Force a known size — ImageRenderer otherwise derives it from
    // intrinsic content size, which on a ZStack with a `.background`
    // can ambiguously round to 0×0.
    renderer.proposedSize = ProposedViewSize(width: 720, height: 452)

    guard let cgImage = renderer.cgImage else {
        FileHandle.standardError.write(Data("error: ImageRenderer produced no CGImage\n".utf8))
        exit(1)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = NSSize(width: 720, height: 452)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("error: PNG encoding failed\n".utf8))
        exit(1)
    }
    try png.write(to: outputURL)
    print("wrote \(outputURL.path) (\(cgImage.width)×\(cgImage.height) px, \(png.count) bytes)")
}

if #available(macOS 13.0, *) {
    do {
        try MainActor.assumeIsolated {
            try renderInstallBackground()
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
} else {
    FileHandle.standardError.write(Data("error: macOS 13.0 or newer required\n".utf8))
    exit(1)
}
