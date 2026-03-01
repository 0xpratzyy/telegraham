import SwiftUI

/// Compact two-line chat row for the launcher results list.
struct ChatRowView: View {
    @EnvironmentObject var telegramService: TelegramService
    @ObservedObject var photoManager = ChatPhotoManager.shared

    let chat: TGChat
    let isHighlighted: Bool
    var priorityReason: String? = nil
    var pipelineStatus: FollowUpItem.Category? = nil
    var pipelineSuggestion: String? = nil
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                AvatarView(
                    initials: chat.initials,
                    colorIndex: chat.colorIndex,
                    size: 26,
                    photo: photoManager.photos[chat.id]
                )
                .onAppear {
                    if let fileId = chat.smallPhotoFileId {
                        photoManager.requestPhoto(chatId: chat.id, fileId: fileId, telegramService: telegramService)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    // Line 1: Title + type badge + unread + time
                    HStack(spacing: 5) {
                        Text(chat.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if let status = pipelineStatus {
                            Circle()
                                .fill(status.color)
                                .frame(width: 6, height: 6)
                        } else {
                            Text(chat.chatType.displayName)
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }

                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
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

                    // Line 2: Preview or priority reason
                    if let reason = priorityReason {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8))
                                .foregroundStyle(.purple)
                            Text(reason)
                                .font(.system(size: 11))
                                .foregroundStyle(.purple.opacity(0.8))
                                .lineLimit(1)
                        }
                    } else if let lastMessage = chat.lastMessage {
                        Text(lastMessage.displayText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Line 3 (pipeline only): AI suggested action
                    if let suggestion = pipelineSuggestion, !suggestion.isEmpty,
                       suggestion != "No action needed" {
                        Text(suggestion)
                            .font(.system(size: 10))
                            .italic()
                            .foregroundStyle(.purple.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
