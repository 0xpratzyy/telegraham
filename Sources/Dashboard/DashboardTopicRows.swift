import SwiftUI

struct DashboardTopicOption: Identifiable {
    let id: Int64
    let name: String
    let rationale: String
    let tint: Color
    let isUncategorized: Bool
}

enum DashboardTopicCommand: String, CaseIterable, Identifiable {
    case allChats
    case catchUp
    case openTasks
    case needsReply

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allChats:
            return "All chats"
        case .catchUp:
            return "Catch me up"
        case .openTasks:
            return "Open tasks"
        case .needsReply:
            return "Needs reply"
        }
    }

    var systemImage: String {
        switch self {
        case .allChats:
            return "bubble.left.and.bubble.right"
        case .catchUp:
            return "clock.arrow.circlepath"
        case .openTasks:
            return "checkmark.square"
        case .needsReply:
            return "tray"
        }
    }
}

struct DashboardTopicChatSignal: Identifiable {
    let chatId: Int64
    let chat: TGChat?
    let title: String
    let typeLabel: String
    let snippet: String
    let lastActivityAt: Date?
    let openTaskCount: Int
    let replyCount: Int

    var id: Int64 { chatId }
}

struct DashboardCatchUpBullet: Identifiable, Equatable {
    let id = UUID()
    let title: String?
    let detail: String

    static func parse(_ summary: String) -> [DashboardCatchUpBullet] {
        summary
            .components(separatedBy: .newlines)
            .compactMap { rawLine -> DashboardCatchUpBullet? in
                let cleaned = clean(rawLine)
                guard !cleaned.isEmpty else { return nil }

                if let separator = cleaned.firstIndex(of: ":") {
                    let title = String(cleaned[..<separator])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail = String(cleaned[cleaned.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty, !detail.isEmpty {
                        return DashboardCatchUpBullet(title: title, detail: detail)
                    }
                }

                return DashboardCatchUpBullet(title: nil, detail: cleaned)
            }
    }

    private static func clean(_ line: String) -> String {
        var text = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")

        while text.hasPrefix("-") || text.hasPrefix("•") || text.hasPrefix("*") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        text = text.replacingOccurrences(
            of: #"^\d+[\.\)]\s*"#,
            with: "",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DashboardCatchUpBulletRow: View {
    let bullet: DashboardCatchUpBullet
    let highlightEntities: [DashboardEntityHighlight]
    let chatById: [Int64: TGChat]
    let onOpenChat: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = bullet.title {
                DashboardHighlightedEntityText(
                    text: title,
                    highlightEntities: highlightEntities,
                    chatById: chatById,
                    onOpenChat: onOpenChat,
                    font: PidgyDashboardTheme.rowEmphasisFont,
                    baseColor: PidgyDashboardTheme.primary
                )
                DashboardHighlightedEntityText(
                    text: bullet.detail,
                    highlightEntities: highlightEntities,
                    chatById: chatById,
                    onOpenChat: onOpenChat,
                    font: PidgyDashboardTheme.detailBodyFont,
                    baseColor: PidgyDashboardTheme.secondary
                )
            } else {
                DashboardHighlightedEntityText(
                    text: bullet.detail,
                    highlightEntities: highlightEntities,
                    chatById: chatById,
                    onOpenChat: onOpenChat,
                    font: PidgyDashboardTheme.detailBodyFont,
                    baseColor: PidgyDashboardTheme.primary
                )
            }
        }
    }
}

struct DashboardHighlightedEntityText: View {
    let text: String
    let highlightEntities: [DashboardEntityHighlight]
    let chatById: [Int64: TGChat]
    let onOpenChat: (Int64) -> Void
    let font: Font
    let baseColor: Color

    var body: some View {
        DashboardInlineFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(Array(Self.segments(in: text, highlightEntities: highlightEntities).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let value):
                    Text(value)
                        .font(font)
                        .foregroundStyle(baseColor)
                        .fixedSize()
                case .entity(let entity):
                    DashboardEntityChip(
                        entity: entity,
                        chat: entity.chatId.flatMap { chatById[$0] },
                        onOpenChat: onOpenChat
                    )
                }
            }
        }
    }

    private enum Segment {
        case text(String)
        case entity(DashboardEntityHighlight)
    }

    private static func segments(in text: String, highlightEntities: [DashboardEntityHighlight]) -> [Segment] {
        let entities = highlightEntities
            .filter { $0.label.count >= 2 }
            .sorted { $0.label.count > $1.label.count }
        guard !entities.isEmpty, !text.isEmpty else {
            return plainSegments(from: text)
        }

        let nsText = text as NSString
        let searchText = text.lowercased() as NSString
        var cursor = 0
        var segments: [Segment] = []

        while cursor < nsText.length {
            let searchRange = NSRange(location: cursor, length: nsText.length - cursor)
            var bestRange: NSRange?
            var bestEntity: DashboardEntityHighlight?

            for entity in entities {
                let range = searchText.range(of: entity.label.lowercased(), options: [], range: searchRange)
                guard range.location != NSNotFound else { continue }
                if let current = bestRange {
                    if range.location < current.location || (range.location == current.location && range.length > current.length) {
                        bestRange = range
                        bestEntity = entity
                    }
                } else {
                    bestRange = range
                    bestEntity = entity
                }
            }

            guard let match = bestRange, let entity = bestEntity else {
                segments.append(contentsOf: plainSegments(from: nsText.substring(from: cursor)))
                break
            }

            if match.location > cursor {
                let plainRange = NSRange(location: cursor, length: match.location - cursor)
                segments.append(contentsOf: plainSegments(from: nsText.substring(with: plainRange)))
            }

            segments.append(.entity(entity))
            cursor = match.location + match.length
        }

        return segments
    }

    private static func plainSegments(from text: String) -> [Segment] {
        text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
            .map(Segment.text)
    }
}

struct DashboardEntityChip: View {
    let entity: DashboardEntityHighlight
    let chat: TGChat?
    let onOpenChat: (Int64) -> Void

    var body: some View {
        Group {
            if let chatId = entity.chatId {
                Button {
                    onOpenChat(chatId)
                } label: {
                    chipContent
                }
                .buttonStyle(.plain)
            } else {
                chipContent
            }
        }
        .help(entity.chatId == nil ? entity.label : "Open \(entity.label)")
    }

    private var chipContent: some View {
        HStack(spacing: 5) {
            DashboardTelegramAvatar(
                chat: chat,
                fallbackTitle: entity.label,
                size: 16
            )

            Text(entity.label)
                .font(PidgyDashboardTheme.captionMediumFont)
                .foregroundStyle(PidgyDashboardTheme.blue)
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(PidgyDashboardTheme.blue.opacity(entity.kind == .person ? 0.16 : 0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(PidgyDashboardTheme.blue.opacity(entity.kind == .person ? 0.5 : 0.36), lineWidth: 1)
        )
        .contentShape(Capsule())
    }
}

struct DashboardInlineFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let maxWidth = proposal.width ?? CGFloat.greatestFiniteMagnitude
        let layout = layout(sizes: sizes, maxWidth: maxWidth)
        return CGSize(width: proposal.width ?? layout.size.width, height: layout.size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let layout = layout(sizes: sizes, maxWidth: max(bounds.width, 1))
        for item in layout.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private struct LayoutItem {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }

    private func layout(sizes: [CGSize], maxWidth: CGFloat) -> (items: [LayoutItem], size: CGSize) {
        guard !sizes.isEmpty else { return ([], .zero) }

        let lineWidth = max(maxWidth, 1)
        var items: [LayoutItem] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for (index, size) in sizes.enumerated() {
            let proposedX = x == 0 ? 0 : x + horizontalSpacing
            if proposedX > 0, proposedX + size.width > lineWidth {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }

            let originX = x == 0 ? 0 : x + horizontalSpacing
            items.append(LayoutItem(index: index, origin: CGPoint(x: originX, y: y), size: size))
            x = originX + size.width
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x)
        }

        return (items, CGSize(width: min(usedWidth, lineWidth), height: y + rowHeight))
    }
}

struct DashboardTopicChatRow: View {
    let signal: DashboardTopicChatSignal

    var body: some View {
        HStack(spacing: 12) {
            DashboardTelegramAvatar(
                chat: signal.chat,
                fallbackTitle: signal.title,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(signal.title)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(signal.typeLabel)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                Text(signal.snippet)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                if signal.replyCount > 0 {
                    DashboardTopicMiniBadge(text: "\(signal.replyCount)", tint: PidgyDashboardTheme.brand)
                }
                if signal.openTaskCount > 0 {
                    DashboardTopicMiniBadge(text: "\(signal.openTaskCount)", tint: PidgyDashboardTheme.blue)
                }
                Text(signal.lastActivityAt.map { DateFormatting.dashboardListTimestamp(from: $0) } ?? "-")
                    .font(PidgyDashboardTheme.monoTimestampFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: PidgyDashboardTheme.topicRowHeight)
        .contentShape(Rectangle())
    }
}

struct DashboardTopicSemanticResultRow: View {
    let result: DashboardTopicSemanticSearchResult
    let chat: TGChat?

    var body: some View {
        HStack(spacing: 12) {
            DashboardTelegramAvatar(
                chat: chat,
                fallbackTitle: result.chatTitle,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    DashboardTopicSourceBadge(source: result.source)
                    Text(result.title)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(result.chatTitle)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(result.senderName)
                        .font(PidgyDashboardTheme.captionMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                    Text(result.snippet)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(result.date.map { DateFormatting.dashboardListTimestamp(from: $0) } ?? "-")
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: PidgyDashboardTheme.topicRowHeight)
        .contentShape(Rectangle())
    }
}

struct DashboardTopicSourceBadge: View {
    let source: DashboardTopicSemanticSearchResult.Source

    var body: some View {
        Text(label)
            .font(PidgyDashboardTheme.monoCaptionFont)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        switch source {
        case .message: return "msg"
        case .task: return "task"
        case .reply: return "reply"
        case .recent: return "recent"
        }
    }

    private var tint: Color {
        switch source {
        case .message: return PidgyDashboardTheme.blue
        case .task: return PidgyDashboardTheme.brand
        case .reply: return PidgyDashboardTheme.purple
        case .recent: return PidgyDashboardTheme.secondary
        }
    }
}

struct DashboardTopicMiniBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(PidgyDashboardTheme.monoCaptionFont)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

struct DashboardMetricPill: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
            Text(label)
                .font(PidgyDashboardTheme.captionMediumFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(DashboardCapsuleBackground())
    }
}
