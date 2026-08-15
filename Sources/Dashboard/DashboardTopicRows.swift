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

/// One themed section of the Catch-me-up digest — parsed from the model's
/// "CATEGORY | Headline | KeyPerson | Detail" line format, with a graceful
/// fallback for unstructured lines (old-format summaries render as plain
/// sections instead of breaking).
struct DashboardCatchUpSection: Identifiable, Equatable {
    /// Position within the parsed summary — part of the identity so two
    /// sections that happen to share category/headline/person (or even
    /// full content) can never collide as duplicate SwiftUI ids.
    let index: Int
    let category: String?
    let headline: String
    let keyPerson: String?
    let detail: String

    /// Content-derived identity, NOT a fresh UUID per parse: reparsing the
    /// same summary must yield the same ids, or SwiftUI treats every
    /// unchanged section as a brand-new row (full re-render + animation
    /// churn on each republish).
    var id: String { "\(index)|\(category ?? "")|\(headline)|\(keyPerson ?? "")|\(detail)" }

    static func parse(_ summary: String) -> [DashboardCatchUpSection] {
        var sections: [DashboardCatchUpSection] = []
        for rawLine in summary.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count >= 4, !parts[1].isEmpty, !parts[3].isEmpty {
                let person = parts[2]
                sections.append(DashboardCatchUpSection(
                    index: sections.count,
                    category: parts[0].isEmpty ? nil : parts[0].uppercased(),
                    headline: parts[1],
                    keyPerson: (person.isEmpty || person == "-") ? nil : person,
                    detail: parts[3]
                ))
                continue
            }
            // Fallback: old bullet format → plain section.
            guard let bullet = DashboardCatchUpBullet.parse(line).first else { continue }
            sections.append(DashboardCatchUpSection(
                index: sections.count,
                category: nil,
                headline: bullet.title ?? bullet.detail,
                keyPerson: nil,
                detail: bullet.title == nil ? "" : bullet.detail
            ))
        }
        return sections
    }
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

/// Skeleton mirroring the editorial Catch-me-up shape (eyebrow bar, big
/// headline bar, chip + prose line) so loading previews the real layout.
struct DashboardCatchUpSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<2, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(PidgyDashboardTheme.rule.opacity(0.6))
                        .padding(.vertical, 14)
                }
                VStack(alignment: .leading, spacing: 12) {
                    bar(width: 130, height: 8)
                    bar(width: index == 0 ? 340 : 260, height: 20)
                    HStack(spacing: 8) {
                        Capsule()
                            .fill(Color.Pidgy.fg2.opacity(pulse ? 0.20 : 0.12))
                            .frame(width: 96, height: 22)
                        bar(width: 240, height: 11)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.Pidgy.fg2.opacity(pulse ? 0.18 : 0.10))
            .frame(width: width, height: height)
    }
}

/// Editorial Catch-me-up section: eyebrow category, serif headline, then a
/// person chip leading one line of prose — magazine digest, not chip soup.
struct DashboardCatchUpSectionRow: View {
    let section: DashboardCatchUpSection
    let chatById: [Int64: TGChat]
    let onOpenChat: (Int64) -> Void
    /// Tapping the headline digs into the theme — the host runs a topic
    /// search on it so evidence/messages for that thread surface below.
    var onExplore: (() -> Void)? = nil
    @State private var isHovering = false

    private var personChat: TGChat? {
        guard let person = section.keyPerson else { return nil }
        let all = Array(chatById.values)
        return all.first { $0.chatType.isPrivate && $0.title.localizedCaseInsensitiveContains(person) }
            ?? all.first { $0.title.localizedCaseInsensitiveContains(person) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.Pidgy.accent.opacity(0.85))
                    .frame(width: 5, height: 5)
                Text("\(section.category ?? "UPDATE")  ·  LAST 30 DAYS")
                    .font(Font.Pidgy.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
            }

            Button {
                onExplore?()
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text(section.headline)
                        .font(PidgyDashboardTheme.sectionTitleFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if onExplore != nil {
                        Image(systemName: "arrow.right")
                            .font(Font.Pidgy.bodySm)
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                            .opacity(isHovering ? 1 : 0)
                            .offset(x: isHovering ? 0 : -4)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onExplore == nil)
            .onHover { hovering in
                withAnimation(PidgyMotion.easeOutFast) { isHovering = hovering }
            }
            .pointerStyle(.link)

            if !section.detail.isEmpty {
                // Person chip flows INLINE with the prose (Text concatenation
                // can't embed views, so chip + first line share an HStack and
                // long details wrap below).
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let person = section.keyPerson {
                        Button {
                            if let chat = personChat { onOpenChat(chat.id) }
                        } label: {
                            HStack(spacing: 6) {
                                // Real profile photo (falls back to initials
                                // while the photo downloads / for no-photo).
                                DashboardTelegramAvatar(
                                    chat: personChat,
                                    fallbackTitle: person,
                                    size: 17
                                )
                                Text(person)
                                    .font(Font.Pidgy.bodyMd)
                                    .foregroundStyle(PidgyDashboardTheme.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(PidgyDashboardTheme.raised))
                            .overlay(Capsule().stroke(Color.Pidgy.border1, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.pidgyPress)
                    }
                    Text(section.detail)
                        .font(Font.Pidgy.body)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
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
        HStack(alignment: .center, spacing: 14) {
            DashboardIdentityAvatar(
                chat: signal.chat,
                label: personName,
                source: sourceKind,
                userID: signal.chat?.lastMessage?.senderUserId,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(personName)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    DashboardInlineSourceLabel(source: sourceKind)
                    if let conversationContext {
                        Text("·")
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                        Text(conversationContext)
                            .font(PidgyDashboardTheme.detailBodyFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(1)
                    }
                }

                Text(previewText)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(signal.lastActivityAt.map { DateFormatting.dashboardListTimestamp(from: $0) } ?? "-")
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 58)
        .pidgyRow()
    }

    private var sourceKind: MessageSourceKind {
        signal.chat?.source.kind ?? .telegram
    }

    private var personName: String {
        if sourceKind == .gmail {
            return GmailPresentation.senderName(from: signal.chat?.lastMessage?.senderName)
        }
        if signal.chat?.chatType.isPrivate == true {
            return signal.title
        }
        return signal.chat?.lastMessage?.senderName ?? signal.title
    }

    private var conversationContext: String? {
        let title = signal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !DashboardTaskPresentation.sameIdentity(title, personName)
        else { return nil }
        return DashboardTaskPresentation.displayConversationTitle(title, source: sourceKind)
    }

    private var previewText: String {
        if sourceKind == .gmail {
            return GmailPresentation.compactBody(
                subject: signal.title,
                messageText: signal.snippet,
                maxCharacters: 180
            )
        }
        return signal.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DashboardTopicSemanticResultRow: View {
    let result: DashboardTopicSemanticSearchResult
    let chat: TGChat?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DashboardIdentityAvatar(
                chat: chat,
                label: personName,
                source: sourceKind,
                userID: chat?.lastMessage?.senderUserId,
                size: PidgyDashboardTheme.rowAvatarSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(personName)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    DashboardInlineSourceLabel(source: sourceKind)
                    if let conversationContext {
                        Text("·")
                            .foregroundStyle(PidgyDashboardTheme.tertiary)
                        Text(conversationContext)
                            .font(PidgyDashboardTheme.detailBodyFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                            .lineLimit(1)
                    }
                }

                Text(secondaryText)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(result.date.map { DateFormatting.dashboardListTimestamp(from: $0) } ?? "-")
                .font(PidgyDashboardTheme.monoTimestampFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .frame(width: PidgyDashboardTheme.timestampColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: 58)
        .pidgyRow()
    }

    private var sourceKind: MessageSourceKind {
        chat?.source.kind ?? .telegram
    }

    private var personName: String {
        if sourceKind == .gmail {
            return GmailPresentation.senderName(from: result.senderName)
        }
        let sender = result.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return sender.isEmpty ? result.chatTitle : sender
    }

    private var conversationContext: String? {
        let title = result.chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !DashboardTaskPresentation.sameIdentity(title, personName),
              !DashboardTaskPresentation.sameText(title, result.title)
        else { return nil }
        return DashboardTaskPresentation.displayConversationTitle(title, source: sourceKind)
    }

    private var secondaryText: String {
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if sourceKind == .gmail {
            return GmailPresentation.compactBody(
                subject: result.chatTitle,
                messageText: result.snippet,
                maxCharacters: 180
            )
        }
        return result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
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
