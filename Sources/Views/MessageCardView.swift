import SwiftUI

struct MessageCardView: View {
    let message: TGMessage
    var highlightQuery: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: chat tag + sender + timestamp
            HStack(spacing: 8) {
                if let chatTitle = message.chatTitle {
                    Text(chatTitle)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                        .lineLimit(1)
                }

                if let senderName = message.senderName {
                    Text(senderName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(message.relativeDate)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // Message text
            if let query = highlightQuery, !query.isEmpty {
                highlightedText(message.displayText, query: query)
            } else {
                Text(message.displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
            }

            // Open in Telegram button
            HStack {
                Spacer()
                Button {
                    DeepLinkGenerator.openMessage(chatId: message.chatId, messageId: message.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                        Text("Open in Telegram")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .opacity(0.7)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    @ViewBuilder
    private func highlightedText(_ text: String, query: String) -> some View {
        let attributedString = createHighlightedString(text, query: query)
        Text(attributedString)
            .font(.system(size: 13))
            .lineLimit(3)
    }

    private func createHighlightedString(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .primary.opacity(0.85)

        // Simple approach: find ranges in the original string and map to AttributedString
        let lowercasedText = text.lowercased()
        let lowercasedQuery = query.lowercased()

        var searchStart = lowercasedText.startIndex
        while let range = lowercasedText.range(of: lowercasedQuery, range: searchStart..<lowercasedText.endIndex) {
            // Convert String.Index to AttributedString range
            if let lowerAttr = AttributedString.Index(range.lowerBound, within: result),
               let upperAttr = AttributedString.Index(range.upperBound, within: result) {
                result[lowerAttr..<upperAttr].foregroundColor = .accentColor
                result[lowerAttr..<upperAttr].font = .system(size: 13, weight: .semibold)
            }
            searchStart = range.upperBound
        }

        return result
    }
}
