import XCTest
@testable import Pidgy

/// Guards the fix for the macOS "Pidgy would like to access files in your
/// Documents folder" prompt: the e5 model must download into Application
/// Support, never the Hugging Face Hub's ~/Documents/huggingface default.
/// That default prompts the user, and on "Don't Allow" the model can't
/// load — search silently falls back to the legacy (weaker, English-
/// leaning) embeddings with no signal to the user.
final class EmbeddingModelPathTests: XCTestCase {
    func testE5ModelDownloadsToApplicationSupportNotDocuments() {
        let url = E5EmbeddingProvider.modelsDirectoryURL

        XCTAssertFalse(
            url.path.contains("/Documents"),
            "e5 weights must NOT download into ~/Documents (that triggers the TCC prompt) — got \(url.path)"
        )

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertTrue(
            url.path.hasPrefix(appSupport.path),
            "models dir must live under Application Support — got \(url.path)"
        )
        XCTAssertEqual(url.lastPathComponent, AppConstants.Storage.modelsDirectoryName)
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            AppConstants.Storage.appSupportFolderName,
            "models dir must sit directly under Application Support/Pidgy"
        )
    }
}
