import AppKit
import Foundation

@MainActor
final class WhatsAppConnectionManager: ObservableObject {
    static let shared = WhatsAppConnectionManager()

    enum ConnectionState: Equatable {
        case unavailable
        case disconnected
        case pairing
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var accountName: String?
    @Published private(set) var accountID: String?
    @Published private(set) var qrCode: String?
    @Published private(set) var lastSyncAt: Date?

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private let importer = WhatsAppLiveImportPipeline()
    private let pairedSessionKey = "pidgy.whatsapp.hasPairedSession"

    private init() {}

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var hasPairedSession: Bool {
        UserDefaults.standard.bool(forKey: pairedSessionKey)
            || FileManager.default.fileExists(atPath: sessionDatabaseURL.path)
    }

    var statusLabel: String {
        switch state {
        case .unavailable: return "Bridge unavailable"
        case .disconnected: return hasPairedSession ? "Reconnect to sync" : "Not connected"
        case .pairing: return "Scan QR with WhatsApp"
        case .connecting: return "Connecting…"
        case .connected: return accountName ?? "Connected read-only"
        case .failed(let message): return message
        }
    }

    func restore() async {
        guard hasPairedSession else { return }
        connect()
    }

    func connect() {
        guard ensureBridgeProcess() else { return }
        state = hasPairedSession ? .connecting : .pairing
        send(command: "connect")
    }

    func reconnect() {
        stop()
        connect()
    }

    func logout() {
        guard ensureBridgeProcess() else { return }
        send(command: "logout")
        accountID = nil
        accountName = nil
        qrCode = nil
        state = .disconnected
    }

    func stop() {
        guard let process else { return }
        send(command: "shutdown")
        process.standardOutput = nil
        process.standardError = nil
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        input = nil
        outputBuffer.removeAll(keepingCapacity: false)
        if isConnected || state == .connecting {
            state = .disconnected
        }
    }

    private var sessionDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pidgy/WhatsApp", isDirectory: true)
    }

    private var sessionDatabaseURL: URL {
        sessionDirectoryURL.appendingPathComponent("session.db", isDirectory: false)
    }

    private func ensureBridgeProcess() -> Bool {
        if let process, process.isRunning { return true }
        guard let bridgeURL = Bundle.main.url(forResource: "pidgy-whatsapp-bridge", withExtension: nil) else {
            state = .unavailable
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: sessionDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionDirectoryURL.path)

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let process = Process()
            process.executableURL = bridgeURL
            process.arguments = ["--store", sessionDatabaseURL.path]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.process = nil
                    self.input = nil
                    if self.isConnected || self.state == .connecting {
                        self.state = .disconnected
                    }
                }
            }
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.consume(data) }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
                NSLog("WhatsApp bridge: %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try process.run()
            self.process = process
            input = inputPipe.fileHandleForWriting
            return true
        } catch {
            state = .failed("Could not start WhatsApp: \(error.localizedDescription)")
            return false
        }
    }

    private func send(command: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["command": command]) else { return }
        var line = data
        line.append(0x0A)
        do {
            try input?.write(contentsOf: line)
        } catch {
            state = .failed("WhatsApp bridge stopped responding.")
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(WhatsAppBridgeEvent.self, from: Data(line)) else { continue }
            handle(event)
        }
    }

    private func handle(_ event: WhatsAppBridgeEvent) {
        if let value = event.accountID, !value.isEmpty { accountID = value }
        if let value = event.accountName, !value.isEmpty { accountName = value }
        switch event.type {
        case "ready", "status":
            if accountID != nil {
                UserDefaults.standard.set(true, forKey: pairedSessionKey)
            }
            if event.status == "connected" {
                state = .connected
            } else if event.status == "unpaired" {
                state = .disconnected
            }
        case "connecting": state = .connecting
        case "qr":
            qrCode = event.code
            state = .pairing
        case "pairing":
            if event.status == "success" { state = .connecting }
        case "connected":
            qrCode = nil
            UserDefaults.standard.set(true, forKey: pairedSessionKey)
            state = .connected
        case "disconnected": state = .disconnected
        case "logged_out":
            qrCode = nil
            accountID = nil
            accountName = nil
            UserDefaults.standard.set(false, forKey: pairedSessionKey)
            state = .disconnected
            stop()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                removeSessionFiles()
            }
        case "history", "message", "metadata":
            guard let conversation = event.conversation else { return }
            let resolvedAccountID = accountID ?? "linked-device"
            let resolvedAccountName = accountName ?? "WhatsApp"
            Task {
                do {
                    try await importer.importConversation(
                        conversation,
                        accountExternalID: resolvedAccountID,
                        accountName: resolvedAccountName,
                        preferExistingTitle: event.type == "message",
                        metadataOnly: event.type == "metadata"
                    )
                    await MainActor.run {
                        self.lastSyncAt = Date()
                        NotificationCenter.default.post(
                            name: .pidgyMessagesUpdatedLocally,
                            object: nil,
                            userInfo: [
                                "messageCount": conversation.messages.count,
                                "source": IntegrationSource.whatsapp.rawValue
                            ]
                        )
                    }
                    await IntegrationConnectionStore.shared.load()
                } catch {
                    await MainActor.run {
                        self.state = .failed("WhatsApp import failed: \(error.localizedDescription)")
                    }
                }
            }
        case "error": state = .failed(event.message ?? "WhatsApp connection failed.")
        default: break
        }
    }

    private func removeSessionFiles() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: sessionDatabaseURL.path + suffix)
        }
    }
}

private struct WhatsAppBridgeEvent: Decodable {
    let type: String
    let code: String?
    let status: String?
    let message: String?
    let accountID: String?
    let accountName: String?
    let conversation: WhatsAppBridgeConversation?

    enum CodingKeys: String, CodingKey {
        case type, code, status, message, conversation
        case accountID = "account_id"
        case accountName = "account_name"
    }
}

private struct WhatsAppBridgeConversation: Decodable, Sendable {
    let id: String
    let title: String
    let kind: String
    let unreadCount: Int
    let updatedAt: Int64
    let messages: [WhatsAppBridgeMessage]
    let avatarURL: String?
    let participants: [WhatsAppBridgeParticipant]?

    enum CodingKeys: String, CodingKey {
        case id, title, kind, messages, participants
        case unreadCount = "unread_count"
        case updatedAt = "updated_at"
        case avatarURL = "avatar_url"
    }
}

private struct WhatsAppBridgeParticipant: Decodable, Sendable {
    let id: String
    let aliases: [String]
    let name: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, aliases, name
        case avatarURL = "avatar_url"
    }
}

private struct WhatsAppBridgeMessage: Decodable, Sendable {
    let id: String
    let chatID: String
    let senderID: String?
    let senderName: String?
    let timestamp: Int64
    let text: String?
    let mediaType: String?
    let fromMe: Bool
    let senderAvatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, text
        case chatID = "chat_id"
        case senderID = "sender_id"
        case senderName = "sender_name"
        case mediaType = "media_type"
        case fromMe = "from_me"
        case senderAvatarURL = "sender_avatar_url"
    }
}

private actor WhatsAppLiveImportPipeline {
    func importConversation(
        _ payload: WhatsAppBridgeConversation,
        accountExternalID: String,
        accountName: String,
        preferExistingTitle: Bool,
        metadataOnly: Bool
    ) async throws {
        let now = Date()
        let accountID = CanonicalID.account(source: .whatsapp, externalID: accountExternalID)
        let account = SourceAccount(
            id: accountID,
            source: .whatsapp,
            externalID: accountExternalID,
            displayName: accountName,
            email: nil,
            connectedAt: now,
            lastSyncedAt: now
        )
        let conversationID = CanonicalID.conversation(
            source: .whatsapp,
            accountID: accountID,
            externalID: payload.id
        )
        let messages = payload.messages.map { message in
            CanonicalMessage(
                id: CanonicalID.message(
                    source: .whatsapp,
                    conversationID: conversationID,
                    externalID: message.id
                ),
                conversationID: conversationID,
                source: .whatsapp,
                externalID: message.id,
                threadRootID: nil,
                senderExternalID: message.senderID,
                senderName: message.fromMe ? "You" : message.senderName,
                subject: nil,
                date: Date(timeIntervalSince1970: TimeInterval(message.timestamp)),
                text: Self.displayText(for: message),
                isOutgoing: message.fromMe,
                isUnread: false,
                senderAvatarURL: message.senderAvatarURL
            )
        }
        let existingTitle: String?
        if preferExistingTitle {
            existingTitle = await DatabaseManager.shared.loadSourceConversations(accountID: accountID)
                .first(where: { $0.externalID == payload.id })?.title
        } else {
            existingTitle = nil
        }
        let conversation = CanonicalConversation(
            id: conversationID,
            accountID: accountID,
            source: .whatsapp,
            externalID: payload.id,
            kind: payload.kind == "group" ? .group : .direct,
            title: existingTitle ?? (payload.title.isEmpty ? "WhatsApp chat" : payload.title),
            updatedAt: payload.updatedAt > 0
                ? Date(timeIntervalSince1970: TimeInterval(payload.updatedAt))
                : messages.map(\.date).max(),
            unreadCount: payload.unreadCount,
            avatarURL: payload.avatarURL
        )
        if metadataOnly || messages.isEmpty {
            try await DatabaseManager.shared.upsertSourceConversation(account: account, conversation: conversation)
        } else {
            try await DatabaseManager.shared.importCanonicalMessages(account: account, conversation: conversation, messages: messages)
        }
        let handles = (payload.participants ?? []).map {
            CanonicalSourceHandle(externalID: $0.id, aliases: $0.aliases, displayName: $0.name, avatarURL: $0.avatarURL)
        }
        if !handles.isEmpty {
            try await DatabaseManager.shared.upsertSourceHandles(sourceID: SourceID(kind: .whatsapp, account: accountExternalID), handles: handles)
        }
    }

    private static func displayText(for message: WhatsAppBridgeMessage) -> String? {
        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        switch message.mediaType {
        case "image": return "[Image]"
        case "video": return "[Video]"
        case "audio": return "[Voice message]"
        case "document": return "[Document]"
        case "sticker": return "[Sticker]"
        default: return nil
        }
    }
}
