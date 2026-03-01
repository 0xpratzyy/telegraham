import SwiftUI
import Combine

/// Manages downloading and caching of Telegram chat profile photos.
@MainActor
class ChatPhotoManager: ObservableObject {
    static let shared = ChatPhotoManager()

    /// chatId → NSImage (cached in memory)
    @Published private(set) var photos: [Int64: NSImage] = [:]

    /// Set of file IDs currently being downloaded (to avoid duplicate requests)
    private var downloading: Set<Int> = []

    private init() {}

    /// Request a photo download for a chat. No-op if already cached or in progress.
    func requestPhoto(chatId: Int64, fileId: Int, telegramService: TelegramService) {
        // Already have it
        if photos[chatId] != nil { return }
        // Already downloading
        if downloading.contains(fileId) { return }

        downloading.insert(fileId)

        Task {
            do {
                let localPath = try await telegramService.downloadFile(fileId: fileId)
                guard !localPath.isEmpty else {
                    downloading.remove(fileId)
                    return
                }

                if let image = NSImage(contentsOfFile: localPath) {
                    photos[chatId] = image
                }
                downloading.remove(fileId)
            } catch {
                downloading.remove(fileId)
                print("[ChatPhotoManager] Failed to download photo for chat \(chatId): \(error)")
            }
        }
    }
}
