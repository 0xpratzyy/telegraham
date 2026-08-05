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
    private var downloadingRemote: Set<Int64> = []
    private var pendingRemotePhotos: [Int64: NSImage] = [:]
    private var remotePublishTask: Task<Void, Never>?

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

    /// Fetch a source-provided HTTPS avatar (Slack DMs use `image_72`). The
    /// same in-memory cache feeds every existing avatar surface, so dashboard,
    /// launcher and detail rows update together when the image arrives.
    func requestPhoto(chatId: Int64, avatarURL: String) {
        guard photos[chatId] == nil, !downloadingRemote.contains(chatId),
              let url = Self.safeRemoteURL(avatarURL) else { return }
        downloadingRemote.insert(chatId)

        Task {
            defer { downloadingRemote.remove(chatId) }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count <= 5_000_000,
                      let image = NSImage(data: data) else { return }
                enqueueRemotePhoto(image, chatId: chatId)
            } catch {
                print("[ChatPhotoManager] Failed to download remote photo for chat \(chatId): \(error)")
            }
        }
    }

    private static func safeRemoteURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    /// Slack avatars finish in a burst when a tab appears. Publish the whole
    /// burst once instead of invalidating every visible row per image.
    private func enqueueRemotePhoto(_ image: NSImage, chatId: Int64) {
        pendingRemotePhotos[chatId] = image
        guard remotePublishTask == nil else { return }
        remotePublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            let batch = self.pendingRemotePhotos
            self.pendingRemotePhotos.removeAll(keepingCapacity: true)
            self.remotePublishTask = nil
            guard !batch.isEmpty else { return }
            var merged = self.photos
            for (id, image) in batch { merged[id] = image }
            self.photos = merged
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
    private var downloadingRemote: Set<Int64> = []
    private var pendingRemotePhotos: [Int64: NSImage] = [:]
    private var remotePublishTask: Task<Void, Never>?

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

    func requestPhoto(userId: Int64, avatarURL: String) {
        guard photos[userId] == nil, !downloadingRemote.contains(userId),
              let url = URL(string: avatarURL), url.scheme?.lowercased() == "https",
              url.host != nil else { return }
        downloadingRemote.insert(userId)

        Task {
            defer { downloadingRemote.remove(userId) }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count <= 5_000_000,
                      let image = NSImage(data: data) else { return }
                enqueueRemotePhoto(
                    Self.circularThumbnail(from: image, side: Self.accountMenuThumbnailSide),
                    userId: userId
                )
            } catch {
                print("[UserPhotoManager] Failed to download remote photo for user \(userId): \(error)")
            }
        }
    }

    private func enqueueRemotePhoto(_ image: NSImage, userId: Int64) {
        pendingRemotePhotos[userId] = image
        guard remotePublishTask == nil else { return }
        remotePublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            let batch = self.pendingRemotePhotos
            self.pendingRemotePhotos.removeAll(keepingCapacity: true)
            self.remotePublishTask = nil
            guard !batch.isEmpty else { return }
            var merged = self.photos
            for (id, image) in batch { merged[id] = image }
            self.photos = merged
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
