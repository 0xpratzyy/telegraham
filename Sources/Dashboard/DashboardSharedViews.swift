import SwiftUI

enum PidgyBranding {
    static let appName = "Pidgy"
    static let dashboardWindowTitle = "Pidgy"
    static let logoAssetName = "PidgyLogo"
    static let dashboardTagline = "Telegram command center"
}

enum PidgyDashboardTheme {
    static let paper = Color.Pidgy.bg1
    static let sidebar = Color.Pidgy.bg2
    static let raised = Color.Pidgy.bg3
    static let deep = Color.Pidgy.bg0
    static let primary = Color.Pidgy.fg1
    static let secondary = Color.Pidgy.fg2
    static let tertiary = Color.Pidgy.fg3
    static let rule = Color.Pidgy.border2
    static let brand = Color.Pidgy.accent
    static let blue = Color.Pidgy.accentFg
    static let green = Color.Pidgy.success
    static let red = Color.Pidgy.danger
    static let yellow = Color.Pidgy.warning
    static let purple = Color.Pidgy.avPurple

    static let pageMaxWidth: CGFloat = 860
    static let pageTopPadding = PidgySpace.s12
    static let pageHorizontalPadding = PidgySpace.s8
    static let pageBottomPadding = PidgySpace.s10 + PidgySpace.s1
    static let headerBottomPadding = PidgySpace.s6
    static let sectionGap = PidgySpace.s6
    static let rowHorizontalPadding = PidgySpace.s3
    static let rowInnerSpacing = PidgySpace.s3
    static let rowHeight: CGFloat = 54
    static let topicRowHeight: CGFloat = 60
    static let compactRowHeight: CGFloat = 50
    static let rowAvatarSize: CGFloat = 28
    static let timestampColumnWidth: CGFloat = 52
    static let sidebarRowHeight: CGFloat = 34

    static let displayTitleFont = Font.Pidgy.displayH1
    static let topicDisplayTitleFont = Font.Pidgy.displayH1
    static let titleFont = Font.Pidgy.h2
    static let pageTitleFont = displayTitleFont
    static let pageSubtitleFont = Font.Pidgy.bodySm
    static let sectionLabelFont = Font.Pidgy.eyebrow
    static let rowTitleFont = Font.Pidgy.bodyMd
    static let rowEmphasisFont = Font.Pidgy.bodyMd
    static let metadataFont = Font.Pidgy.bodySm
    static let metadataMediumFont = Font.Pidgy.bodyMd
    static let detailBodyFont = Font.Pidgy.bodySm
    static let captionFont = Font.Pidgy.meta
    static let captionMediumFont = Font.Pidgy.eyebrow
    static let monoTimestampFont = Font.Pidgy.monoSm
    static let monoCaptionFont = Font.Pidgy.monoSm
    static let selectedRowCornerRadius = PidgyRadius.md

    static func topicTint(_ seed: Int64) -> Color {
        let palette = [
            Color.Pidgy.avBlue,
            Color.Pidgy.info,
            Color.Pidgy.avGreen,
            Color.Pidgy.avPurple,
            Color.Pidgy.avPink,
            Color.Pidgy.fg2
        ]
        return palette[abs(Int(seed % Int64(palette.count)))]
    }
}

struct PidgyMascotMark: View {
    let size: CGFloat

    var body: some View {
        Image(PidgyBranding.logoAssetName)
            .resizable()
            .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.white.opacity(0.24))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 4, y: 2)
    }
}

struct DashboardSkeletonRows: View {
    var count: Int = 6
    var showAvatar = true
    var showTimestamp = true

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                DashboardSkeletonRow(
                    titleWidth: titleWidth(for: index),
                    subtitleWidth: subtitleWidth(for: index),
                    showAvatar: showAvatar,
                    showTimestamp: showTimestamp
                )
            }
        }
        .accessibilityLabel("Loading")
    }

    private func titleWidth(for index: Int) -> CGFloat {
        [260, 340, 300, 390, 230, 320][index % 6]
    }

    private func subtitleWidth(for index: Int) -> CGFloat {
        [360, 260, 420, 310, 380, 290][index % 6]
    }
}

struct DashboardSkeletonRow: View {
    let titleWidth: CGFloat
    let subtitleWidth: CGFloat
    let showAvatar: Bool
    let showTimestamp: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showAvatar {
                DashboardSkeletonBlock(
                    width: PidgyDashboardTheme.rowAvatarSize,
                    height: PidgyDashboardTheme.rowAvatarSize,
                    cornerRadius: PidgyDashboardTheme.rowAvatarSize / 2
                )
            }

            VStack(alignment: .leading, spacing: 7) {
                DashboardSkeletonBlock(width: titleWidth, height: 12, cornerRadius: 5)
                DashboardSkeletonBlock(width: subtitleWidth, height: 10, cornerRadius: 5)
            }

            Spacer(minLength: 12)

            if showTimestamp {
                DashboardSkeletonBlock(width: 34, height: 11, cornerRadius: 5)
            }
        }
        .padding(.horizontal, PidgyDashboardTheme.rowHorizontalPadding)
        .frame(height: PidgyDashboardTheme.topicRowHeight)
    }
}

struct DashboardSkeletonTextBlock: View {
    var lineCount: Int = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<lineCount, id: \.self) { index in
                DashboardSkeletonBlock(
                    width: [620, 760, 700, 520, 660][index % 5],
                    height: 13,
                    cornerRadius: 6
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Loading")
    }
}

struct DashboardSkeletonHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardSkeletonBlock(width: 112, height: 26, cornerRadius: 13)
            DashboardSkeletonBlock(width: 260, height: 24, cornerRadius: 8)
            DashboardSkeletonBlock(width: 320, height: 12, cornerRadius: 6)
        }
        .accessibilityLabel("Loading")
    }
}

struct DashboardSkeletonBlock: View {
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 6
    @State private var isPulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(PidgyDashboardTheme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PidgyDashboardTheme.primary.opacity(isPulsing ? 0.08 : 0.025))
            )
            .frame(width: width, height: height)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

struct DashboardInitialsAvatar: View {
    let label: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: max(9, size * 0.34), weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                avatarColor.opacity(0.95),
                                avatarColor.opacity(0.62)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(Circle().stroke(Color.white.opacity(0.12)))
    }

    private var avatarColor: Color {
        PidgyDashboardTheme.topicTint(Int64(abs(label.hashValue % 997)))
    }

    private var initials: String {
        let words = label.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        }
        return String(label.prefix(2)).uppercased()
    }
}

struct DashboardTelegramAvatar: View {
    @EnvironmentObject private var telegramService: TelegramService
    @ObservedObject private var photoManager = ChatPhotoManager.shared

    let chat: TGChat?
    let fallbackTitle: String
    var size = PidgyDashboardTheme.rowAvatarSize

    var body: some View {
        AvatarView(
            initials: chat?.initials ?? fallbackInitials,
            colorIndex: chat?.colorIndex ?? abs(fallbackTitle.hashValue % 8),
            size: size,
            photo: chat.flatMap { photoManager.photos[$0.id] }
        )
        .onAppear(perform: requestPhotoIfNeeded)
    }

    private var fallbackInitials: String {
        let words = fallbackTitle.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        }
        return String(fallbackTitle.prefix(2)).uppercased()
    }

    private func requestPhotoIfNeeded() {
        guard let chat, let fileId = chat.smallPhotoFileId else { return }
        photoManager.requestPhoto(chatId: chat.id, fileId: fileId, telegramService: telegramService)
    }
}

struct DashboardTelegramUserAvatar: View {
    @EnvironmentObject private var telegramService: TelegramService
    @ObservedObject private var photoManager = UserPhotoManager.shared

    let user: TGUser?
    let fallbackTitle: String
    var size: CGFloat = PidgyDashboardTheme.rowAvatarSize

    var body: some View {
        AvatarView(
            initials: user?.initials ?? fallbackInitials,
            colorIndex: colorIndex,
            size: size,
            photo: user.flatMap { photoManager.photos[$0.id] }
        )
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.12)))
        .onAppear(perform: requestPhotoIfNeeded)
        .onChange(of: user?.smallPhotoFileId) {
            requestPhotoIfNeeded()
        }
    }

    private var colorIndex: Int {
        if let user {
            return abs(Int(user.id % 8))
        }
        return abs(fallbackTitle.hashValue % 8)
    }

    private var fallbackInitials: String {
        let words = fallbackTitle.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    private func requestPhotoIfNeeded() {
        guard let user, let fileId = user.smallPhotoFileId else { return }
        photoManager.requestPhoto(userId: user.id, fileId: fileId, telegramService: telegramService)
    }
}

struct DashboardEvidenceRow: View {
    let source: DashboardTaskSourceMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(source.senderName)
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                Text(DateFormatting.compactRelativeTime(from: source.date))
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Spacer()
                Text("#\(source.messageId)")
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
            }
            Text(source.text)
                .font(PidgyDashboardTheme.detailBodyFont)
                .italic()
                .foregroundStyle(PidgyDashboardTheme.primary)
                .lineLimit(4)
                .lineSpacing(2)
        }
        .padding(10)
        .background(PidgyDashboardTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}

struct DashboardDetailPane<Content: View, Actions: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if !(Actions.self == EmptyView.self) {
                HStack(spacing: 8) {
                    actions
                }
                .font(PidgyDashboardTheme.metadataMediumFont)
                .padding(16)
                .background(PidgyDashboardTheme.deep)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(PidgyDashboardTheme.rule)
                        .frame(height: 1)
                }
            }
        }
        .background(PidgyDashboardTheme.raised)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(width: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .padding(10)
        }
    }
}

struct DashboardDetailCover<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(PidgyDashboardTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 1)
        }
    }
}

struct DashboardDetailSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .tracking(0.8)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(PidgyDashboardTheme.monoCaptionFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }
            }
            content
        }
        .padding(22)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 1)
        }
    }
}

struct DashboardPersonColumn<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text("\(count)")
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(18)
    }
}

struct DashboardTopicChip: View {
    let text: String
    let tint: Color
    var small = false

    var body: some View {
        Text(text)
            .font(PidgyDashboardTheme.captionMediumFont)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, small ? 7 : 8)
            .padding(.vertical, small ? 2 : 3)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.32)))
    }
}

struct DashboardPriorityDot: View {
    var priority: DashboardTaskPriority?
    var color: Color?

    var body: some View {
        Circle()
            .fill(color ?? priority.map(priorityColor) ?? PidgyDashboardTheme.secondary)
            .frame(width: 6, height: 6)
    }
}

struct DashboardSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(PidgyDashboardTheme.sectionLabelFont)
            .foregroundStyle(PidgyDashboardTheme.secondary)
    }
}

struct DashboardEmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(PidgyDashboardTheme.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PidgyDashboardTheme.primary)
            Text(subtitle)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(28)
    }
}

struct DashboardSmallEmptyText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(PidgyDashboardTheme.metadataFont)
            .foregroundStyle(PidgyDashboardTheme.secondary)
            .padding(.vertical, 6)
    }
}

struct DashboardCapsuleBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(PidgyDashboardTheme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PidgyDashboardTheme.rule)
            )
    }
}

struct DashboardFilterCapsule: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(PidgyDashboardTheme.metadataFont)
            Text("\(title):")
                .font(PidgyDashboardTheme.metadataMediumFont)
            Text(value)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(PidgyDashboardTheme.secondary)
        .frame(height: 28)
        .padding(.horizontal, 10)
        .background(DashboardCapsuleBackground())
    }
}

struct DashboardSegmentedReplyFilter: View {
    @Binding var selection: DashboardReplyFilter
    let needsCount: Int
    let allCount: Int
    let mutedCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.needsYou, count: needsCount)
            segment(.allOpen, count: allCount)
            segment(.muted, count: mutedCount)
        }
    }

    private func segment(_ filter: DashboardReplyFilter, count: Int) -> some View {
        Button {
            selection = filter
        } label: {
            HStack(spacing: 6) {
                Text(filter.label)
                Text("\(count)")
                    .foregroundStyle(selection == filter ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.tertiary)
            }
            .font(PidgyDashboardTheme.metadataMediumFont)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(selection == filter ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == filter ? PidgyDashboardTheme.raised : Color.clear)
                    .shadow(color: selection == filter ? Color.black.opacity(0.22) : Color.clear, radius: 6, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DashboardStatusSegments: View {
    @Binding var selection: DashboardStatusFilter
    let openCount: Int
    let doneCount: Int
    let allCount: Int
    var onSelect: (DashboardStatusFilter) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            segment(.open, count: openCount)
            segment(.done, count: doneCount)
            segment(.all, count: allCount)
        }
    }

    private func segment(_ filter: DashboardStatusFilter, count: Int) -> some View {
        Button {
            selection = filter
            onSelect(filter)
        } label: {
            HStack(spacing: 5) {
                Text(filter.label)
                Text("\(count)")
                    .foregroundStyle(selection == filter ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.tertiary)
            }
            .font(PidgyDashboardTheme.metadataMediumFont)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .foregroundStyle(selection == filter ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selection == filter ? PidgyDashboardTheme.raised : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct DashboardPeopleTabs: View {
    @Binding var selection: DashboardPeopleLens
    let needsCount: Int
    let keyCount: Int
    let coldCount: Int
    let recentCount: Int
    let allCount: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                tab(.needsYou, count: needsCount)
                tab(.keyPeople, count: keyCount)
                tab(.goingCold, count: coldCount)
                tab(.recent, count: recentCount)
                tab(.all, count: allCount)
            }
        }
    }

    private func tab(_ filter: DashboardPeopleLens, count: Int) -> some View {
        Button {
            selection = filter
        } label: {
            HStack(spacing: 5) {
                Text(filter.label)
                Text("\(count)")
                    .font(PidgyDashboardTheme.monoCaptionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            .font(PidgyDashboardTheme.metadataMediumFont)
            .foregroundStyle(selection == filter ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
    }
}

func categoryTint(_ category: FollowUpItem.Category) -> Color {
    switch category {
    case .onMe:
        return PidgyDashboardTheme.yellow
    case .onThem:
        return PidgyDashboardTheme.brand
    case .quiet:
        return PidgyDashboardTheme.secondary
    }
}
