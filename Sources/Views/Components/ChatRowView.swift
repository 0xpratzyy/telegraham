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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let status = pipelineStatus {
                            Text(status.rawValue)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(status.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(status.color.opacity(0.15))
                                .clipShape(Capsule())
                        } else {
                            Text(chat.chatType.displayName)
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }

                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }

                        Spacer()

                        if let date = chat.lastActivityDate {
                            Text(DateFormatting.compactRelativeTime(from: date))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Line 2: Pipeline suggestion, or message preview
                    if let suggestion = pipelineSuggestion, !suggestion.isEmpty,
                       suggestion != "No action needed", pipelineStatus != nil {
                        Text("→ \(suggestion)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let messagePreview {
                        if !messagePreview.isEmpty {
                            Text(messagePreview)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if let lastMessage = chat.lastMessage {
                        Text(lastMessage.displayText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
