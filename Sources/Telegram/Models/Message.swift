import Foundation

struct TGMessage: Identifiable, Equatable {
    let id: Int64
    let chatId: Int64
    let senderId: MessageSenderId
    let date: Date
    let textContent: String?
    let mediaType: MediaType?
    let chatTitle: String?
    let senderName: String?

    enum MessageSenderId: Equatable {
        case user(Int64)
        case chat(Int64)
    }

    enum MediaType: String, Equatable {
        case photo = "Photo"
        case video = "Video"
        case document = "Document"
        case audio = "Audio"
        case voice = "Voice"
        case sticker = "Sticker"
        case animation = "GIF"
        case other = "Media"
    }

    /// Returns text content or a media type placeholder
    var displayText: String {
        if let text = textContent, !text.isEmpty {
            return text
        }
        if let media = mediaType {
            return "[\(media.rawValue)]"
        }
        return "[Message]"
    }

    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
