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
/// Creates a single client instance and provides a restartable AsyncStream of updates.
/// The TDLibKit.TDLibClient is exposed so TelegramService can call its named methods directly.
final class TDLibClientWrapper {
    private var manager: TDLibClientManager?
    private(set) var client: TDLibKit.TDLibClient?
    private var updateContinuation: AsyncStream<Update>.Continuation?
    private(set) var updates: AsyncStream<Update>
#if DEBUG
    private(set) var updateStreamGenerationForTesting = 0
#endif

    init() {
        let stream = Self.makeUpdateStream()
        updates = stream.updates
        updateContinuation = stream.continuation
    }

    func start(apiId: Int, apiHash: String) {
        if manager != nil || client != nil {
            close()
        } else if updateContinuation == nil {
            resetUpdateStream()
        }
        let activeContinuation = updateContinuation
        manager = TDLibClientManager()

        client = manager?.createClient(updateHandler: { [weak self] data, client in
            guard self != nil else { return }
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                activeContinuation?.yield(update)
            } catch {
                print("[TDLib] Failed to decode update: \(error)")
            }
        })
    }

    func close() {
        updateContinuation?.finish()
        updateContinuation = nil
        manager?.closeClients()
        manager = nil
        client = nil
        resetUpdateStream()
    }

    private func resetUpdateStream() {
        let stream = Self.makeUpdateStream()
        updates = stream.updates
        updateContinuation = stream.continuation
#if DEBUG
        updateStreamGenerationForTesting += 1
#endif
    }

    private static func makeUpdateStream() -> (
        updates: AsyncStream<Update>,
        continuation: AsyncStream<Update>.Continuation
    ) {
        var continuation: AsyncStream<Update>.Continuation!
        let updates = AsyncStream<Update> { continuation = $0 }
        return (updates, continuation)
    }

    static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("Pidgy/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        return dbDir.path
    }
}
