//
//  PidgyFontRegistrar.swift
//  Pidgy
//

import AppKit
import CoreText
import Foundation
import OSLog

enum PidgyFontRegistrar {
    static let fontsSubdirectory = "Fonts"
    static let bundledFontFilenames = [
        "Inter[opsz,wght].ttf",
        "Newsreader[opsz,wght].ttf",
        "JetBrainsMono[wght].ttf"
    ]

    private static let logger = Logger(subsystem: "com.pidgy.app", category: "fonts")
    private static let lock = NSLock()
    private static var hasRegisteredFonts = false

    @discardableResult
    static func registerBundledFonts(bundle: Bundle = .main) -> [URL] {
        lock.lock()
        if hasRegisteredFonts {
            lock.unlock()
            return []
        }
        hasRegisteredFonts = true
        lock.unlock()

        guard let resourceURL = bundle.resourceURL else {
            logger.error("Unable to register bundled fonts: bundle has no resource URL.")
            return []
        }

        // xcodegen flattens loose .ttf files inside Sources/Resources/Fonts/
        // into Contents/Resources/ when generating the project. Try the
        // historical Fonts/ subdirectory first (in case a future build keeps
        // the folder reference), fall back to the bundle root.
        let fontDirectoryURL = resourceURL.appendingPathComponent(fontsSubdirectory, isDirectory: true)
        return bundledFontFilenames.compactMap { filename in
            let nestedURL = fontDirectoryURL.appendingPathComponent(filename)
            let flatURL = resourceURL.appendingPathComponent(filename)
            let url: URL
            if FileManager.default.fileExists(atPath: nestedURL.path) {
                url = nestedURL
            } else if FileManager.default.fileExists(atPath: flatURL.path) {
                url = flatURL
            } else {
                logger.error("Bundled font missing: \(filename, privacy: .public) (looked in \(fontDirectoryURL.path, privacy: .public) and \(resourceURL.path, privacy: .public))")
                return nil
            }

            var registrationError: Unmanaged<CFError>?
            let didRegister = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &registrationError
            )

            if didRegister {
                // Log the actual family + face names so call sites in
                // PidgyTokens can be sanity-checked against the real font.
                if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                    for descriptor in descriptors {
                        let family = (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String) ?? "?"
                        let postScript = (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String) ?? "?"
                        logger.info("Registered font \(filename, privacy: .public): family=\(family, privacy: .public) postScript=\(postScript, privacy: .public)")
                    }
                }
                return url
            }

            if let error = registrationError?.takeRetainedValue() {
                logger.error("Unable to register bundled font \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else {
                logger.error("Unable to register bundled font \(filename, privacy: .public).")
            }
            return nil
        }
    }
}
