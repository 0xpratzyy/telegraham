import SwiftUI

/// Clean two-line chat row for the launcher results list.
struct ChatRowView: View {
    @EnvironmentObject var telegramService: TelegramService
    @ObservedObject var photoManager = ChatPhotoManager.shared

    let chat: TGChat
    let isHighlighted: Bool
    var pipelineStatus: FollowUpItem.Category? = nil
    var pipelineSuggestion: String? = nil
    var messagePreview: String? = nil
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                AvatarView(
                    initials: chat.initials,
                    colorIndex: chat.colorIndex,
                    size: 32,
                    photo: photoManager.photos[chat.id]
                )
                .onAppear {
                    if let fileId = chat.smallPhotoFileId {
                        photoManager.requestPhoto(chatId: chat.id, fileId: fileId, telegramService: telegramService)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    // Line 1: Title + status/type badge + unread + time
                    HStack(spacing: 5) {
                        Text(chat.title)
                            .font(Font.Pidgy.bodyMd)
                            .foregroundStyle(Color.Pidgy.fg1)
                            .lineLimit(1)

                        if let status = pipelineStatus {
                            Text(status.rawValue)
                                .font(Font.Pidgy.eyebrow)
                                .foregroundStyle(status.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(status.color.opacity(0.15))
                                .clipShape(Capsule())
                        } else {
                            Text(chat.chatType.displayName)
                                .font(Font.Pidgy.monoSm)
                                .foregroundStyle(Color.Pidgy.fg3)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.Pidgy.bg4.opacity(0.55))
                                .clipShape(Capsule())
                        }

                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(Font.Pidgy.monoSm)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.Pidgy.accent)
                                .clipShape(Capsule())
                        }

                        Spacer()

                        if let date = chat.lastActivityDate {
                            Text(DateFormatting.compactRelativeTime(from: date))
                                .font(Font.Pidgy.monoSm)
                                .foregroundStyle(Color.Pidgy.fg3)
                        }
                    }

                    // Line 2: Pipeline suggestion, or message preview
                    if let suggestion = pipelineSuggestion, !suggestion.isEmpty,
                       suggestion != "No action needed", pipelineStatus != nil {
                        Text("→ \(suggestion)")
                            .font(Font.Pidgy.bodySm)
                            .foregroundStyle(Color.Pidgy.fg2)
                            .lineLimit(1)
                    } else if let messagePreview {
                        if !messagePreview.isEmpty {
                            Text(messagePreview)
                                .font(Font.Pidgy.bodySm)
                                .foregroundStyle(Color.Pidgy.fg2)
                                .lineLimit(1)
                        }
                    } else if let lastMessage = chat.lastMessage {
                        Text(lastMessage.displayText)
                            .font(Font.Pidgy.bodySm)
                            .foregroundStyle(Color.Pidgy.fg2)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? Color.Pidgy.bg4 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
