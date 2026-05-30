import Foundation

struct TGMessage: Identifiable, Equatable, Sendable {
    let id: Int64
    let chatId: Int64
    let senderId: MessageSenderId
    let date: Date
    let textContent: String?
    let mediaType: MediaType?
    let isOutgoing: Bool
    let chatTitle: String?
    let senderName: String?
    /// Which account this message came from. Defaults to `.telegram`.
    let source: SourceID

    init(
        id: Int64,
        chatId: Int64,
        senderId: MessageSenderId,
        date: Date,
        textContent: String?,
        mediaType: MediaType?,
        isOutgoing: Bool,
        chatTitle: String?,
        senderName: String?,
        source: SourceID = .telegram
    ) {
        self.id = id
        self.chatId = chatId
        self.senderId = senderId
        self.date = date
        self.textContent = textContent
        self.mediaType = mediaType
        self.isOutgoing = isOutgoing
        self.chatTitle = chatTitle
        self.senderName = senderName
        self.source = source
    }

    func updating(textContent: String?) -> TGMessage {
        TGMessage(
            id: id, chatId: chatId, senderId: senderId, date: date,
            textContent: textContent, mediaType: mediaType, isOutgoing: isOutgoing,
            chatTitle: chatTitle, senderName: senderName, source: source
        )
    }

    enum MessageSenderId: Equatable, Sendable {
        case user(Int64)
        case chat(Int64)
    }

    enum MediaType: String, Equatable, Sendable {
        case photo = "Photo"
        case video = "Video"
        case document = "Document"
        case audio = "Audio"
        case voice = "Voice"
        case sticker = "Sticker"
        case animation = "GIF"
        case other = "Media"
    }

    var normalizedTextContent: String? {
        guard let textContent else { return nil }
        let cleaned = textContent
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Returns text content or a media type placeholder
    var displayText: String {
        if let text = normalizedTextContent {
            return text
        }
        if let media = mediaType {
            return "[\(media.rawValue)]"
        }
        return "[Message]"
    }

    var relativeDate: String {
        DateFormatting.compactRelativeTime(from: date)
    }

    var senderUserId: Int64? {
        if case .user(let userId) = senderId {
            return userId
        }
        return nil
    }
}
