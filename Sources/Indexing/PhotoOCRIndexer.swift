import Foundation
import Vision
import AppKit

/// On-device OCR over cached photo messages (Apple Vision — no network, no
/// AI cost). Recognized text is appended to the message's text_content as
/// "[photo text: …]", so fact extraction, FTS search, and evidence rows all
/// see what was in the screenshot (payment confirmations, invoices, tickets)
/// with zero reader changes. Runs a small budgeted batch per extraction pass,
/// newest photos first; failures stay pending and retry next pass.
final class PhotoOCRIndexer {
    static let shared = PhotoOCRIndexer()
    private var isRunning = false
    /// Flipped by stop() so an in-flight batch stops WRITING even if its
    /// task's cancellation flag never trips (e.g. it was started from an
    /// unstructured context). Reset by the next runPass.
    private var stopped = false

    /// Halt the current batch at the next checkpoint. The critical property:
    /// after stop(), no further applyPhotoOCR writes happen — reset deletes
    /// the database right behind this.
    func stop() {
        stopped = true
    }

    func runPass(telegramService: TelegramService, limit: Int = 24) async {
        guard !isRunning else { return }
        isRunning = true
        stopped = false
        defer { isRunning = false }

        let pending = await DatabaseManager.shared.pendingPhotoOCRMessages(limit: limit)
        guard !pending.isEmpty else { return }

        for item in pending {
            guard !Task.isCancelled, !stopped else { break }
            do {
                guard let path = try await telegramService.downloadMessagePhoto(
                    chatId: item.chatId, messageId: item.id
                ) else {
                    guard !Task.isCancelled, !stopped else { break }
                    // Not a photo anymore (deleted/edited) — mark done so it
                    // doesn't spin forever.
                    await DatabaseManager.shared.applyPhotoOCR(messageId: item.id, chatId: item.chatId, text: nil)
                    continue
                }
                // The download is the long await — a cancel/stop that landed
                // during it must be honored BEFORE the write, or the "row
                // stays pending, retry next pass" contract turns into a write
                // into a database that reset is about to delete.
                guard !Task.isCancelled, !stopped else { break }
                let text = Self.recognizeText(at: URL(fileURLWithPath: path))
                guard !Task.isCancelled, !stopped else { break }
                await DatabaseManager.shared.applyPhotoOCR(messageId: item.id, chatId: item.chatId, text: text)
            } catch {
                // Transient (network / rate limit / client not ready) — leave
                // pending; the next pass retries.
                continue
            }
        }
    }

    /// Synchronous Vision OCR — accurate mode with language detection.
    /// Returns nil when nothing readable was found.
    static func recognizeText(at url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.3 }
            .map(\.string)
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
