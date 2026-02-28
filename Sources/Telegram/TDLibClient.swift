import Foundation
import TDLibKit

enum TGError: LocalizedError {
    case clientNotInitialized
    case invalidResponse
    case authenticationRequired
    case allChatsFailed

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "TDLib client is not initialized"
        case .invalidResponse:
            return "Invalid response from TDLib"
        case .authenticationRequired:
            return "Authentication required"
        case .allChatsFailed:
            return "Failed to fetch messages from all chats"
        }
    }
}

/// Low-level TDLib client wrapper using TDLibKit.
/// Creates a single client instance and provides an AsyncStream of updates.
/// The TDLibKit.TDLibClient is exposed so TelegramService can call its named methods directly.
final class TDLibClientWrapper {
    private var manager: TDLibClientManager?
    private(set) var client: TDLibKit.TDLibClient?
    private let updateContinuation: AsyncStream<Update>.Continuation
    let updates: AsyncStream<Update>

    init() {
        var continuation: AsyncStream<Update>.Continuation!
        updates = AsyncStream { continuation = $0 }
        updateContinuation = continuation
    }

    func start(apiId: Int, apiHash: String) {
        manager = TDLibClientManager()

        client = manager?.createClient(updateHandler: { [weak self] data, client in
            guard let self else { return }
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                self.updateContinuation.yield(update)
            } catch {
                print("[TDLib] Failed to decode update: \(error)")
            }
        })
    }

    func close() {
        updateContinuation.finish()
        manager?.closeClients()
        manager = nil
        client = nil
    }

    static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("TGSearch/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        return dbDir.path
    }
}
