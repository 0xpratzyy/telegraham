#!/usr/bin/env swift

//
//  scripts/render_app_icon.swift
//
//  Bakes the dark rounded-square Pidgy app icon used everywhere
//  Finder, the Dock, Spotlight, and Launchpad draw the app — including
//  the slot in the .dmg install window, where the icon Finder draws
//  over (188, 220) IS the .icns from the .app itself.
//
//  Output: PNG files at every macOS app-icon size (16, 32, 128, 256,
//  512 at 1x and 2x), written into
//  Sources/Resources/Assets.xcassets/AppIcon.appiconset/, where
//  xcodebuild compiles them into AppIcon.icns during the build.
//
//  Design matches the InstallWelcomeWindow's `PidgyAppIconView`:
//      - Dark radial gradient #4A4B52 → #2E2F34 → #1E1F23
//      - Rounded-square shape, 22% radius (matches macOS Big Sur+)
//      - Mascot photo inside, offset 6% down to match the live
//        view's `object-position: center 30%` framing
//      - Subtle top highlight + bottom shade for the Big Sur "vignette"
//
//  Run:
//      swift scripts/render_app_icon.swift
//

import AppKit
import SwiftUI

// MARK: - Icon view

@available(macOS 13.0, *)
struct AppIconView: View {
    let size: CGFloat
    let mascot: NSImage

    // Big Sur+ uses a 22% squircle radius. Standard border-radius
    // approximates it well enough at this scale.
    private var cornerRadius: CGFloat { size * 0.22 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0x4A / 255.0, green: 0x4B / 255.0, blue: 0x52 / 255.0),
                            Color(red: 0x2E / 255.0, green: 0x2F / 255.0, blue: 0x34 / 255.0),
                            Color(red: 0x1E / 255.0, green: 0x1F / 255.0, blue: 0x23 / 255.0)
                        ],
                        center: UnitPoint(x: 0.3, y: 0.2),
                        startRadius: size * 0.03,
                        endRadius: size * 1.1
                    )
                )

            Image(nsImage: mascot)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size * 1.16, height: size * 1.16)
                .offset(y: size * 0.06) // pull mascot up so the head sits higher
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // Top-light / bottom-shade vignette — gives the icon the
            // subtle dimensional read every modern macOS icon has.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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

            // Hairline stroke so the dark shell doesn't dissolve when
            // shown over a dark background (e.g. Dock at night).
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: max(0.5, size * 0.005))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Render

@available(macOS 13.0, *)
@MainActor
func renderAppIcon() throws {
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let projectRoot: URL = {
        let sd = scriptURL.deletingLastPathComponent()
        if sd.lastPathComponent == "scripts" {
            return sd.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    let mascotURL = projectRoot.appendingPathComponent(
        "Sources/Resources/Assets.xcassets/PidgyMascotPhoto.imageset/pidgy-mascot.png"
    )
    guard let mascot = NSImage(contentsOf: mascotURL) else {
        FileHandle.standardError.write(Data("error: cannot read mascot at \(mascotURL.path)\n".utf8))
        exit(1)
    }

    let outDir = projectRoot.appendingPathComponent(
        "Sources/Resources/Assets.xcassets/AppIcon.appiconset"
    )
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // (logical size, scale, filename) — covers every entry in the
    // existing Contents.json so xcodebuild's Asset Catalog Compiler
    // is happy.
    let entries: [(Int, Int, String)] = [
        (16,  1, "appicon-16.png"),
        (16,  2, "appicon-16@2x.png"),
        (32,  1, "appicon-32.png"),
        (32,  2, "appicon-32@2x.png"),
        (128, 1, "appicon-128.png"),
        (128, 2, "appicon-128@2x.png"),
        (256, 1, "appicon-256.png"),
        (256, 2, "appicon-256@2x.png"),
        (512, 1, "appicon-512.png"),
        (512, 2, "appicon-512@2x.png")
    ]

    for (logical, scale, filename) in entries {
        let px = logical * scale
        let view = AppIconView(size: CGFloat(logical), mascot: mascot)
        let renderer = ImageRenderer(content: view)
        renderer.scale = CGFloat(scale)
        renderer.proposedSize = ProposedViewSize(width: CGFloat(logical), height: CGFloat(logical))
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("error: render failed for \(filename)\n".utf8))
            exit(1)
        }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        bitmap.size = NSSize(width: logical, height: logical)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("error: PNG encoding failed for \(filename)\n".utf8))
            exit(1)
        }
        let url = outDir.appendingPathComponent(filename)
        try png.write(to: url)
        print("wrote \(filename) (\(px)×\(px) px, \(png.count) bytes)")
    }
}

if #available(macOS 13.0, *) {
    do {
        try MainActor.assumeIsolated {
            try renderAppIcon()
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
} else {
    FileHandle.standardError.write(Data("error: macOS 13.0 or newer required\n".utf8))
    exit(1)
}
