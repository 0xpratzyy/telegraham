import SwiftUI

enum PidgyBranding {
    static let appName = "Pidgy"
    static let dashboardWindowTitle = "Pidgy"
    static let logoAssetName = "PidgyLogo"
    static let dashboardTagline = "Telegram command center"
}

enum PidgyDashboardTheme {
    // Inverted from the original (sidebar brighter than main) so the
    // main pane is the brighter surface and the sidebar reads as the
    // chrome around it. Lines up better with macOS apps that put
    // the workspace forward (Notes, Mail).
    static let paper = Color.Pidgy.bg2
    static let sidebar = Color.Pidgy.bg1
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

    /// Newsreader 36pt — only the hero pages (Dashboard "What to do now",
    /// Topic workspace name).
    static let heroTitleFont = Font.Pidgy.heroTitle
    /// Newsreader 32pt — every other page-level title (Reply queue, Tasks,
    /// People, About) and the big numeric values on Pricing.
    static let pageTitleFont = Font.Pidgy.pageTitle
    /// Newsreader 22pt — section heads, drawer titles, CatchMeUp headlines.
    static let sectionTitleFont = Font.Pidgy.sectionTitle
    /// Newsreader 26pt — StatTile big values + Donut label.
    static let statValueFont = Font.Pidgy.statValue
    /// Newsreader 24pt — task detail title.
    static let taskDetailTitleFont = Font.Pidgy.taskDetailTitle
    /// Newsreader 19pt — sidebar "Pidgy" wordmark.
    static let brandTitleFont = Font.Pidgy.brand

    // Legacy aliases kept until call sites migrate.
    static let displayTitleFont = Font.Pidgy.heroTitle
    static let titleFont = Font.Pidgy.h2
    static let pageSubtitleFont = Font.Pidgy.bodySm
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

/// Sidebar shortcut button that opens the launcher panel. Has a subtle
/// hover state — bg lightens to bg-4 and label text steps up from
/// tertiary to secondary — matching the design's hover treatment.
struct SidebarLauncherShortcutButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Ask anything…")
                    .font(PidgyDashboardTheme.metadataFont)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("⌘K")
                    .font(Font.Pidgy.monoSm)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(PidgyDashboardTheme.sidebar)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(PidgyDashboardTheme.rule, lineWidth: 1)
                            )
                    )
            }
            .foregroundStyle(isHovering ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.Pidgy.bg4 : PidgyDashboardTheme.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.Pidgy.border1, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PidgyMotion.easeOutFast, value: isHovering)
        .help("Search or ask anything (⌘K)")
    }
}

/// Soft hand-drawn squiggle divider used under the dashboard / topic page
/// titles. Pure SwiftUI so the line is crisp at any width.
struct DashboardSquiggleDivider: View {
    var amplitude: CGFloat = 4
    var wavelength: CGFloat = 12
    var lineWidth: CGFloat = 1
    var opacity: Double = 0.22

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let mid = proxy.size.height / 2
            Path { path in
                path.move(to: CGPoint(x: 0, y: mid))
                var x: CGFloat = 0
                var up = true
                while x < width {
                    let nextX = min(x + wavelength, width)
                    let controlX = (x + nextX) / 2
                    let controlY = up ? mid - amplitude : mid + amplitude
                    path.addQuadCurve(
                        to: CGPoint(x: nextX, y: mid),
                        control: CGPoint(x: controlX, y: controlY)
                    )
                    x = nextX
                    up.toggle()
                }
            }
            .stroke(
                PidgyDashboardTheme.tertiary.opacity(opacity),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
        .frame(height: amplitude * 2 + lineWidth)
        .accessibilityHidden(true)
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

/// One visual contract for identity across the multi-source dashboard.
///
/// The person/conversation stays primary: use a real profile photo whenever
/// the source can resolve one, then fall back to stable initials. Source
/// identity belongs beside the row title (matching the launcher), not on top
/// of the person's photo.
struct DashboardIdentityAvatar: View {
    @EnvironmentObject private var sourceRegistry: SourceRegistry

    let chat: TGChat?
    let label: String
    var source: MessageSourceKind? = nil
    var userID: Int64? = nil
    var size: CGFloat = PidgyDashboardTheme.rowAvatarSize
    var showsSource = false

    @State private var resolvedUser: TGUser?

    var body: some View {
        identity
            .overlay(alignment: .bottomTrailing) {
                if showsSource {
                    DashboardSourceMark(source: resolvedSource, avatarSize: size)
                        .offset(x: size >= 36 ? 2 : 1.5, y: size >= 36 ? 2 : 1.5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(resolvedSource.displayName)")
            .task(id: userLookupID) {
                await resolveUserIfNeeded()
            }
    }

    @ViewBuilder
    private var identity: some View {
        if let resolvedUser {
            DashboardTelegramUserAvatar(
                user: resolvedUser,
                fallbackTitle: label,
                size: size
            )
        } else if shouldUseConversationAvatar {
            DashboardTelegramAvatar(
                chat: chat,
                fallbackTitle: label,
                size: size
            )
        } else {
            DashboardInitialsAvatar(label: label, size: size)
        }
    }

    private var resolvedSource: MessageSourceKind {
        source ?? chat?.source.kind ?? .telegram
    }

    private var shouldUseConversationAvatar: Bool {
        guard let chat, resolvedSource != .gmail else { return false }
        return chat.chatType.isOneOnOne || sameIdentity(label, chat.title)
    }

    private var userLookupID: String {
        "\(chat?.source.rawValue ?? resolvedSource.rawValue):\(userID ?? 0)"
    }

    @MainActor
    private func resolveUserIfNeeded() async {
        let expectedLookupID = userLookupID
        resolvedUser = nil
        guard let chat, let userID else {
            return
        }
        let user = try? await sourceRegistry.source(for: chat)?.user(id: userID)
        guard !Task.isCancelled, expectedLookupID == userLookupID else { return }
        resolvedUser = user
    }

    private func sameIdentity(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Compact launcher-style provider label used after a row's primary title.
/// Every source gets the same provenance treatment so rows remain scannable
/// when Gmail, Slack, Telegram, and WhatsApp are mixed together.
struct DashboardInlineSourceLabel: View {
    let source: MessageSourceKind

    var body: some View {
        Label(source.displayName, systemImage: source.systemImage)
            .font(Font.Pidgy.monoSm)
            .foregroundStyle(PidgyDashboardTheme.brand)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .accessibilityLabel(source.displayName)
    }
}

enum DashboardSourceMetadata {
    static func providerLine(source: MessageSourceKind, age: String) -> String {
        "\(source.displayName)  ·  \(age)"
    }

    static func accountLabel(
        source: MessageSourceKind,
        account: String,
        connectedGmailAccountCount: Int
    ) -> String? {
        let email = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source == .gmail, connectedGmailAccountCount > 1, !email.isEmpty else { return nil }
        return email
    }
}

private struct DashboardSourceMark: View {
    let source: MessageSourceKind
    let avatarSize: CGFloat

    var body: some View {
        Image(systemName: source.systemImage)
            .font(.system(size: markSize * 0.43, weight: .bold))
            .foregroundStyle(PidgyDashboardTheme.primary)
            .frame(width: markSize, height: markSize)
            .background(PidgyDashboardTheme.deep, in: Circle())
            .overlay(Circle().stroke(PidgyDashboardTheme.rule, lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.18), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }

    private var markSize: CGFloat {
        avatarSize >= 36 ? 16 : 13
    }
}

struct DashboardTelegramAvatar: View {
    @Environment(\.telegramServiceReference) private var telegramService
    @ObservedObject private var photoManager = ChatPhotoManager.shared

    let chat: TGChat?
    let fallbackTitle: String
    var size = PidgyDashboardTheme.rowAvatarSize

    var body: some View {
        AvatarView(
            initials: chat?.initials ?? fallbackInitials,
            colorIndex: chat?.colorIndex ?? abs(fallbackTitle.hashValue % 8),
            size: size,
            photo: chat.flatMap { photoManager.photos[$0.id] },
            // Groups + channels render as rounded squares (Telegram
            // convention) so the list scans faster — squircle = group,
            // circle = person. Falls back to circle when the chat hasn't
            // been resolved yet (unknown chats default to person-shape).
            shape: (chat?.chatType.isOneOnOne ?? true) ? .circle : .squircle
        )
        .onAppear(perform: requestPhotoIfNeeded)
        .onChange(of: chat?.avatarURL) {
            requestPhotoIfNeeded()
        }
    }

    private var fallbackInitials: String {
        let words = fallbackTitle.split(separator: " ")
        if words.count >= 2 {
            return "\(words[0].prefix(1))\(words[1].prefix(1))".uppercased()
        }
        return String(fallbackTitle.prefix(2)).uppercased()
    }

    private func requestPhotoIfNeeded() {
        guard let chat else { return }
        if let fileId = chat.smallPhotoFileId, let telegramService {
            photoManager.requestPhoto(chatId: chat.id, fileId: fileId, telegramService: telegramService)
        } else if let avatarURL = chat.avatarURL {
            photoManager.requestPhoto(chatId: chat.id, avatarURL: avatarURL)
        }
    }
}

struct DashboardTelegramUserAvatar: View {
    @Environment(\.telegramServiceReference) private var telegramService
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
        .onChange(of: user?.avatarURL) {
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
        guard let user else { return }
        if let fileId = user.smallPhotoFileId, let telegramService {
            photoManager.requestPhoto(userId: user.id, fileId: fileId, telegramService: telegramService)
        } else if let avatarURL = user.avatarURL {
            photoManager.requestPhoto(userId: user.id, avatarURL: avatarURL)
        }
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
        // Design spec calls for a soft hint at 12pt fg-3 in sentence
        // case — not the all-caps eyebrow style. Using bodySm (Inter
        // 13, regular) is the closest stop on our ramp; tertiary (fg-3
        // at 0.42 opacity) drops the visual weight so the section
        // labels read as "rest your eyes here" hints rather than UI
        // chrome. The 8pt leading pad puts the label flush with the
        // row content (avatar) below — Dashboard.jsx's eyebrow uses
        // `paddingLeft: 8` and rows use `padding: '10px 8px'`, so
        // both land at the same x.
        Text(title)
            .font(PidgyDashboardTheme.metadataFont)
            .foregroundStyle(PidgyDashboardTheme.tertiary)
            .padding(.leading, 8)
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

/// "Still populating" state — shown while a surface (Tasks / Reply queue) is
/// being filled by the extraction crawl, instead of a bare empty state that
/// reads as "broken". Simple and honest: the line-art loader plus one line
/// saying what's happening and where results will land.
struct DashboardPigeonLoader: View {
    var title: String = "Reading your chats…"
    var subtitle: String = "New items land here as Pidgy works through the last 30 days."

    var body: some View {
        VStack(spacing: 12) {
            PidgyLoader(size: 38)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PidgyDashboardTheme.primary)
            Text(subtitle)
                .font(PidgyDashboardTheme.detailBodyFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
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
    /// Driven by the host control's hover state via `.pidgyCapsuleBackground()`.
    /// `.onHover` does NOT fire on a view used as a `.background`, so hover has
    /// to be tracked on the foreground control and passed in here.
    var isHovering: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(PidgyDashboardTheme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.06 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovering ? Color.Pidgy.border3 : PidgyDashboardTheme.rule)
            )
    }
}

/// Hover-aware capsule chrome. Binds `.onHover` to the CONTENT (a foreground
/// view, where it actually fires — unlike a `.background` view) and feeds the
/// state into the capsule. The reliable replacement for
/// `.background(DashboardCapsuleBackground())`.
struct PidgyCapsuleHover: ViewModifier {
    @State private var isHovering = false
    func body(content: Content) -> some View {
        content
            .background(DashboardCapsuleBackground(isHovering: isHovering))
            .pointerStyle(.link)
            .onHover { isHovering = $0 }
            .animation(PidgyMotion.hover, value: isHovering)
    }
}

extension View {
    /// Drop-in hover-aware replacement for `.background(DashboardCapsuleBackground())`.
    func pidgyCapsuleBackground() -> some View { modifier(PidgyCapsuleHover()) }
}

/// The standard list-row treatment in ONE token: selected fill + hover
/// highlight + pointing-hand cursor, at the shared row corner radius. Baked
/// into every row component (DashboardTaskRow, DashboardFeedRow, DashboardPersonRow,
/// DashboardAttentionRow, …) so hover + selection are automatic and identical
/// everywhere the row is used — no per-screen wiring, nothing to forget.
struct PidgyRowStyle: ViewModifier {
    var isSelected: Bool = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: PidgyDashboardTheme.selectedRowCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.Pidgy.bg4 : (isHovering ? Color.white.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { isHovering = $0 }
            .animation(PidgyMotion.hover, value: isHovering)
    }
}

extension View {
    /// Selected fill + hover highlight + pointing-hand cursor — the one row token.
    func pidgyRow(isSelected: Bool = false) -> some View {
        modifier(PidgyRowStyle(isSelected: isSelected))
    }
}

/// Shared search-input chrome — rounded 14pt corners, sidebar-tinted fill,
/// hairline border, faint lifted shadow. Matches the design system's
/// "Claude-style" input used on Topic and People pages so search affordances
/// look identical across the app.
struct DashboardSearchFieldBackground: View {
    var radius: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.Pidgy.bg2)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PidgyDashboardTheme.rule)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
    }
}

/// Shared search-input field. Three size variants cover every
/// current call site (reply queue, topics, people, tasks owner
/// popover) so we don't end up with 4 slightly-different
/// implementations again. Always shows the magnifying-glass leading
/// icon, optional clear (×) button trailing once there's text. Pass
/// an optional `maxWidth` to cap the standard/prominent variants on
/// wide layouts.
struct DashboardSearchField: View {
    enum Size {
        /// Height 28pt. For controls rows alongside segmented filters
        /// (reply queue) and inside popovers (tasks owner picker).
        case compact
        /// Height ~36pt. For inline list filters (people page).
        case standard
        /// Height ~60pt. For page-level hero search (topics page).
        case prominent
    }

    let placeholder: String
    @Binding var text: String
    var size: Size = .standard
    var maxWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: iconGap) {
            Image(systemName: "magnifyingglass")
                .font(iconFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
            TextField(placeholder, text: $text)
                .font(textFont)
                .textFieldStyle(.plain)
                .foregroundStyle(PidgyDashboardTheme.primary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(iconFont)
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(background)
        .frame(maxWidth: maxWidth ?? .infinity)
    }

    // MARK: - Size-derived constants

    private var iconGap: CGFloat {
        switch size {
        case .compact: return 7
        case .standard: return 8
        case .prominent: return 10
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .compact: return 10
        case .standard: return 12
        case .prominent: return 16
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .compact: return 6
        case .standard: return 10
        case .prominent: return 20
        }
    }

    private var iconFont: Font {
        switch size {
        case .compact: return .system(size: 11, weight: .medium)
        case .standard: return PidgyDashboardTheme.metadataMediumFont
        case .prominent: return PidgyDashboardTheme.metadataMediumFont
        }
    }

    private var textFont: Font {
        switch size {
        case .compact: return PidgyDashboardTheme.detailBodyFont
        case .standard: return PidgyDashboardTheme.metadataFont
        case .prominent: return PidgyDashboardTheme.rowTitleFont
        }
    }

    @ViewBuilder
    private var background: some View {
        switch size {
        case .compact:
            // Tight, no shadow — sits inline with other 28pt
            // controls (sort toggle, segmented filter) and shouldn't
            // visually dominate them.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PidgyDashboardTheme.sidebar)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(PidgyDashboardTheme.rule, lineWidth: 1)
                )
        case .standard, .prominent:
            DashboardSearchFieldBackground()
        }
    }
}

struct DashboardSegmentedReplyFilter: View {
    @Binding var selection: DashboardReplyFilter
    let onMeCount: Int
    let onThemCount: Int
    let quietCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.onMe, count: onMeCount)
            segment(.onThem, count: onThemCount)
            segment(.quiet, count: quietCount)
        }
        // Outer rounded container — gives the filter a clear pill
        // boundary so it reads as one control rather than three
        // floating buttons. The fill is `sidebar` so it sits one
        // step deeper than the `raised` active-segment fill — that
        // contrast is what makes the selected segment pop above
        // the container. Now mirrors the FollowUpItem.Category
        // model (.onMe / .onThem / .quiet) end-to-end.
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PidgyDashboardTheme.sidebar)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(PidgyDashboardTheme.rule.opacity(0.55), lineWidth: 1)
                )
        )
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
            .frame(height: 28)
            .foregroundStyle(selection == filter ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == filter ? PidgyDashboardTheme.raised : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                selection == filter ? PidgyDashboardTheme.rule.opacity(0.7) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .pidgyHoverRow(cornerRadius: 8)
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
        .pidgyHoverRow(cornerRadius: 7)
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
        .pidgyHoverRow(cornerRadius: 8)
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
