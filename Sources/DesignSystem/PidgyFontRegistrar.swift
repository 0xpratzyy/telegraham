//
//  PidgyFontRegistrar.swift
//  Pidgy
//

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

        let fontDirectoryURL = resourceURL.appendingPathComponent(fontsSubdirectory, isDirectory: true)
        return bundledFontFilenames.compactMap { filename in
            let url = fontDirectoryURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger.error("Bundled font missing: \(url.path, privacy: .public)")
                return nil
            }

            var registrationError: Unmanaged<CFError>?
            let didRegister = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &registrationError
            )

            if didRegister {
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
