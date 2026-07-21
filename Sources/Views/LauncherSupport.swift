import SwiftUI

enum LauncherChatPreviewResolver {
    enum Source: Equatable {
        case currentMessage
        case recentContext
        case none
    }

    struct Resolution: Equatable {
        let text: String
        let source: Source
    }

    static let contextMessageLimit = 10

    static func resolvePreview(for chat: TGChat, recentMessages: [TGMessage]) -> Resolution {
        guard let lastMessage = chat.lastMessage else {
            return Resolution(text: "", source: .none)
        }

        if let currentText = meaningfulPreviewText(for: lastMessage) {
            return Resolution(text: currentText, source: .currentMessage)
        }

        let contextualMessages = recentMessages
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id > $1.id
            }
            .filter { $0.id != lastMessage.id }

        if let recentContext = contextualMessages.compactMap(meaningfulPreviewText).first {
            return Resolution(text: recentContext, source: .recentContext)
        }

        return Resolution(text: "", source: .none)
    }

    static func shouldFetchRecentContext(
        for chat: TGChat,
        recentMessages: [TGMessage],
        currentResolution: Resolution,
        cachedMessageCount: Int
    ) -> Bool {
        guard let lastMessage = chat.lastMessage else { return false }
        guard meaningfulPreviewText(for: lastMessage) == nil else { return false }
        guard currentResolution.source != .recentContext else { return false }
        if cachedMessageCount < contextMessageLimit {
            return true
        }
        return recentMessages.contains { message in
            guard let text = message.normalizedTextContent else { return false }
            return isSyntheticPlaceholderText(text)
        }
    }

    private static func meaningfulPreviewText(for message: TGMessage) -> String? {
        guard let text = message.normalizedTextContent else { return nil }
        return isSyntheticPlaceholderText(text) ? nil : text
    }

    private static func isSyntheticPlaceholderText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let syntheticLabels: Set<String> = [
            "[photo]", "photo",
            "[video]", "video", "video note",
            "[document]", "document",
            "[audio]", "audio",
            "[voice]", "voice", "voice note",
            "[sticker]", "sticker",
            "[gif]", "gif",
            "[media]", "media",
            "[message]", "message",
            "contact",
            "poll",
            "venue",
            "location",
            "live location",
            "emoji"
        ]

        return syntheticLabels.contains(normalized)
    }
}

// MARK: - Onboarding handoff

/// Shown in the launcher panel when Telegram isn't authenticated yet.
/// Onboarding is now done in a dedicated window (OnboardingWindowController),
/// so the panel just nudges the user there instead of duplicating the QR /
/// phone-login UI in two places.
struct LauncherOnboardingHandoff: View {
    var body: some View {
        VStack(spacing: PidgySpace.s4) {
            PidgyMascotMark(size: 56)
            VStack(spacing: PidgySpace.s2) {
                Text("Finish setting up Pidgy")
                    .font(Font.Pidgy.h3)
                    .foregroundStyle(Color.Pidgy.fg1)
                Text("Connect Telegram in the welcome window to start using the launcher.")
                    .font(Font.Pidgy.bodySm)
                    .foregroundStyle(Color.Pidgy.fg3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, PidgySpace.s6)
            Button {
                NotificationCenter.default.post(name: .pidgyShowOnboardingWindow, object: nil)
            } label: {
                Text("Open welcome window")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.Pidgy.bg1)
                    .padding(.horizontal, PidgySpace.s5)
                    .padding(.vertical, PidgySpace.s3)
                    .background(
                        RoundedRectangle(cornerRadius: PidgyRadius.md, style: .continuous)
                            .fill(Color.Pidgy.fg1)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PidgySpace.s6)
    }
}
