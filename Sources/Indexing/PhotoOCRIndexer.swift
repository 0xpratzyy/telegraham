import Foundation
import Vision
import AppKit

/// Vision performs native work outside Swift Task cancellation. Track its
/// lifetime explicitly so process finalizers cannot race a live MPS graph.
final class OCRWorkTracker: @unchecked Sendable {
    static let shared = OCRWorkTracker()
    private let lock = NSLock()
    private var stopping = false
    private var terminated = false
    private var work: [UUID: @Sendable () -> Void] = [:]

    var isStopped: Bool { locked { stopping } }
    var hasActiveWork: Bool { locked { !work.isEmpty } }

    func begin(cancel: @escaping @Sendable () -> Void) -> UUID? {
        locked {
            guard !stopping else { return nil }
            let id = UUID()
            work[id] = cancel
            return id
        }
    }
    func finish(_ id: UUID) { locked { _ = work.removeValue(forKey: id) } }
    func stop(permanently: Bool = false) {
        let cancellations = locked {
            stopping = true
            terminated = terminated || permanently
            return Array(work.values)
        }
        // Never call external cancellation while holding the bookkeeping lock.
        cancellations.forEach { $0() }
    }
    func resume() { locked { if !terminated { stopping = false } } }
    func waitUntilIdle(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(max(0, timeout) * 1_000)))
        while hasActiveWork && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
        }
        return !hasActiveWork
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// On-device OCR over cached photo messages (Apple Vision). Optional TypeSafe
/// classification and a text-provider sentence add metered network calls.
/// Recognized text is appended to the message's text_content as
/// "[photo text: …]", so fact extraction, FTS search, and evidence rows all
/// see what was in the screenshot (payment confirmations, invoices, tickets)
/// with zero reader changes. Runs a small budgeted batch per extraction pass,
/// newest photos first; failures stay pending and retry next pass.
final class PhotoOCRIndexer {
    static let shared = PhotoOCRIndexer()
    private let passLock = NSLock()
    private var isRunning = false
    /// Flipped by stop() so an in-flight batch stops WRITING even if its
    /// task's cancellation flag never trips (e.g. it was started from an
    /// unstructured context). Re-armed ONLY by resume() (called from
    /// FactExtractionCoordinator.start()) — runPass must NOT reset it, or a
    /// pass resuming after stop() would un-latch shutdown by itself.
    private var stopped: Bool { OCRWorkTracker.shared.isStopped }

    /// Halt the current batch at the next checkpoint. The critical property:
    /// after stop(), no further applyPhotoOCR writes happen — reset deletes
    /// the database right behind this.
    func stop() {
        OCRWorkTracker.shared.stop()
    }

    func stopForTermination() {
        OCRWorkTracker.shared.stop(permanently: true)
    }

    /// Re-arm after a previous stop(). Called only from the crawl
    /// coordinator's start(), i.e. an explicit new lifecycle.
    func resume() {
        OCRWorkTracker.shared.resume()
    }

    func runPass(telegramService: TelegramService, aiService: AIService, limit: Int = 24) async {
        guard beginPass() else { return }
        defer { endPass() }

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
                let summary: String?
                if let text { summary = try? await aiService.summarizeImageText(text) }
                else { summary = nil }
                guard !Task.isCancelled, !stopped else { break }
                await DatabaseManager.shared.applyPhotoOCR(messageId: item.id, chatId: item.chatId, text: text, summary: summary)
            } catch {
                // Transient (network / rate limit / client not ready) — leave
                // pending; the next pass retries.
                continue
            }
        }
    }

    private func beginPass() -> Bool {
        passLock.lock()
        defer { passLock.unlock() }
        guard !isRunning, !stopped else { return false }
        isRunning = true
        return true
    }
    private func endPass() {
        passLock.lock()
        isRunning = false
        passLock.unlock()
    }

    /// Synchronous Vision OCR — accurate mode with language detection.
    /// Returns nil when nothing readable was found.
    static func recognizeText(at url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        guard let workID = OCRWorkTracker.shared.begin(cancel: { request.cancel() }) else { return nil }
        defer { OCRWorkTracker.shared.finish(workID) }
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
