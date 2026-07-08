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
    /// ONE manager for the entire process, never torn down. td_receive is
    /// GLOBAL — TDLib aborts ("Receive must not be called simultaneously from
    /// two different threads") if two threads call it, and every
    /// TDLibClientManager spawns its own infinite receive loop that lingers in
    /// td_receive(10) for up to 10s after release. Re-creating the manager on
    /// re-auth briefly ran two loops → the Sentry SIGABRT. Clients are the
    /// per-session unit; the manager (and its single receive thread) is forever.
    private static let sharedManager = TDLibClientManager()

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
        if client != nil {
            close()
        } else if updateContinuation == nil {
            resetUpdateStream()
        }
        let activeContinuation = updateContinuation

        let newClient = Self.sharedManager.createClient(updateHandler: { [weak self] data, client in
            guard self != nil else { return }
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                activeContinuation?.yield(update)
            } catch {
                print("[TDLib] Failed to decode update: \(error)")
            }
        })

        // Silence TDLib's internal C++ logger ASAP. Default verbosity is 5
        // (VERBOSE) which dumps every request/response payload — when stderr
        // is redirected to a file this historically grew /private/tmp/pidgy.log
        // to 254 GB. `setLogVerbosityLevel` is one of TDLib's synchronous
        // methods so it takes effect process-wide via td_execute. There's a
        // tiny window between createClient and this call where verbose chatter
        // still flows; that's bounded to a few KB at startup.
        do {
            _ = try newClient.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
        } catch {
            print("[TDLib] Failed to lower log verbosity: \(error)")
        }
        client = newClient
    }

    func close() {
        updateContinuation?.finish()
        updateContinuation = nil
        // Fire-and-forget close of OUR client only — NEVER closeClients():
        // that call hot-spins (`while !clients.isEmpty {}`) until TDLib
        // finishes flushing, which on the main actor was the Sentry
        // "App Hanging ≥ 2000 ms" at every quit and re-auth. TDLib starts
        // flushing on the close REQUEST, the shared manager prunes the client
        // when authorizationStateClosed arrives, and tdlib recovers cleanly on
        // next launch even if the process exits before the close completes.
        // The old client's update handler only yields into the just-finished
        // continuation, so its remaining updates are no-ops.
        if let client {
            try? client.close(completion: { _ in })
        }
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

    /// Wait (bounded, never on the main thread's behalf — callers await from a
    /// Task) until TDLib finishes closing every client. Quit must not race
    /// TDLib's teardown: exit() while td is mid-WAL-checkpoint aborted in
    /// td::Scheduler::clear() (SIGABRT at quit). The manager prunes clients on
    /// authorizationStateClosed; the short grace afterwards lets td's worker
    /// threads finish joining before process teardown runs.
    static func waitUntilClosed(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !sharedManager.clients.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("Pidgy/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        return dbDir.path
    }
}
