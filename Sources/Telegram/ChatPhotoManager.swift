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

/// Manages downloading and caching Telegram user profile photos.
@MainActor
final class UserPhotoManager: ObservableObject {
    static let shared = UserPhotoManager()
    static let accountMenuThumbnailSide: CGFloat = 17

    @Published private(set) var photos: [Int64: NSImage] = [:]

    private var downloading: Set<Int> = []

    private init() {}

    func requestPhoto(userId: Int64, fileId: Int, telegramService: TelegramService) {
        guard photos[userId] == nil, !downloading.contains(fileId) else { return }

        downloading.insert(fileId)

        Task {
            do {
                let localPath = try await telegramService.downloadFile(fileId: fileId)
                guard !localPath.isEmpty else {
                    downloading.remove(fileId)
                    return
                }

                if let image = NSImage(contentsOfFile: localPath) {
                    photos[userId] = Self.circularThumbnail(from: image, side: Self.accountMenuThumbnailSide)
                }
                downloading.remove(fileId)
            } catch {
                downloading.remove(fileId)
                print("[UserPhotoManager] Failed to download photo for user \(userId): \(error)")
            }
        }
    }

    private static func circularThumbnail(from image: NSImage, side: CGFloat) -> NSImage {
        let targetSize = NSSize(width: side, height: side)
        let targetRect = NSRect(origin: .zero, size: targetSize)
        let thumbnail = NSImage(size: targetSize)

        thumbnail.lockFocus()
        NSBezierPath(ovalIn: targetRect).addClip()

        let sourceSize = image.size
        let widthScale = side / max(sourceSize.width, 1)
        let heightScale = side / max(sourceSize.height, 1)
        let scale = max(widthScale, heightScale)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: (side - drawSize.width) / 2,
            y: (side - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        thumbnail.unlockFocus()

        return thumbnail
    }
}
