import SwiftUI

// Ask Pidgy chat (#48) — one conversation engine + thread UI shared by every
// surface that can ask: the launcher's chat mode, the dashboard's bottom
// "Ask anything" bar (Granola-style), and the Topics page. The engine is the
// fast fact+rolling-summary answerer with multi-turn history.

@MainActor
final class AskPidgyChatModel: ObservableObject {
    struct Turn: Identifiable, Equatable {
        enum Role { case user, pidgy }
        let id = UUID()
        let createdAt = Date()
        let role: Role
        var text: String
        var isError = false
    }

    @Published var thread: [Turn] = []
    @Published var isAnswering = false
    private var answerTask: Task<Void, Never>?

    var hasFlaggableAnswer: Bool {
        thread.contains { $0.role == .pidgy && !$0.isError }
    }

    /// Start a fresh conversation with `question` as the first user bubble.
    func start(with question: String, aiService: AIService) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        answerTask?.cancel()
        thread = [Turn(role: .user, text: q)]
        runAnswerTurn(aiService: aiService)
    }

    /// Append a follow-up user turn and answer it with the thread as history.
    func send(_ text: String, aiService: AIService) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }
        thread.append(Turn(role: .user, text: q))
        runAnswerTurn(aiService: aiService)
    }

    func reset() {
        answerTask?.cancel()
        isAnswering = false
        thread = []
    }

    private func runAnswerTurn(aiService: AIService) {
        guard let question = thread.last(where: { $0.role == .user })?.text else { return }
        isAnswering = true
        answerTask?.cancel()
        answerTask = Task { @MainActor in
            do {
                let history = thread.dropLast().map {
                    (role: $0.role == .user ? "user" : "assistant", text: $0.text)
                }
                let reply = try await aiService.answerQuestion(question, history: history)
                guard !Task.isCancelled else { return }
                thread.append(Turn(role: .pidgy, text: reply))
            } catch {
                guard !Task.isCancelled else { return }
                thread.append(Turn(
                    role: .pidgy,
                    text: "Couldn’t answer right now — try again.",
                    isError: true
                ))
            }
            isAnswering = false
        }
    }

    /// Flag the latest answer — same review-first feedback flow as search.
    func flagLatestAnswer() {
        let lastQuestion = thread.last(where: { $0.role == .user })?.text ?? ""
        let lastAnswer = thread.last(where: { $0.role == .pidgy && !$0.isError })?.text
        let fixture = FlaggedAnswerFixture(
            query: lastQuestion,
            route: "askPidgyChat",
            resultTitle: nil,
            resultText: lastAnswer,
            supportingSnippets: []
        )
        fixture.submitToFeedbackSheetPresentingDashboard()
    }
}

// MARK: - Thread view (bubbles only; the composer is the host's field)

struct AskPidgyThreadView: View {
    @ObservedObject var model: AskPidgyChatModel
    @EnvironmentObject private var telegramService: TelegramService
    @State private var isHoveringThread = false

    var body: some View {
        // Bottom-anchored like a real messaging thread: with few messages the
        // conversation sits just above the composer instead of floating at
        // the top of an empty panel.
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.thread.enumerated()), id: \.element.id) { index, turn in
                            Group {
                                if turn.role == .user {
                                    userBubble(turn)
                                } else {
                                    pidgyBubble(turn)
                                }
                            }
                            // Question→answer sit close; a new question gets
                            // more air — reads as turn pairs, not a flat list.
                            .padding(.top, index == 0 ? 0 : (turn.role == .user ? 18 : 8))
                            .transition(.asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(y: 16))
                                    .combined(with: .scale(scale: 0.96, anchor: turn.role == .user ? .bottomTrailing : .bottomLeading)),
                                removal: .opacity
                            ))
                        }
                        if model.isAnswering {
                            thinkingBubble
                                .padding(.top, 8)
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        }
                        if !model.isAnswering, model.hasFlaggableAnswer {
                            HStack {
                                Spacer()
                                Button(action: model.flagLatestAnswer) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "flag")
                                            .font(Font.Pidgy.meta)
                                        Text("Flag this answer")
                                            .font(Font.Pidgy.meta)
                                    }
                                    .foregroundStyle(Color.Pidgy.fg3)
                                }
                                .buttonStyle(.plain)
                                .opacity(isHoveringThread ? 0.9 : 0.35)
                                .help("Opens Send Feedback prefilled with this question and answer — you review everything before sending.")
                            }
                            .padding(.top, 8)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottomLeading)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.thread)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isAnswering)
                }
                .onChange(of: model.thread) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: model.isAnswering) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
        }
        .onHover { isHoveringThread = $0 }
        // Backlinks: answers cite people/chats as pidgy://chat/<id> markdown
        // links (the prompt hands the model each item's chat id). A click
        // resolves the cached chat and deep-links straight into Telegram.
        .environment(\.openURL, OpenURLAction { url in
            // Only pidgy://chat/<id> is clickable. Anything else in an answer
            // came from message content the model read — swallowing it keeps
            // an injected web link from becoming a trusted-looking button.
            guard url.scheme == "pidgy", url.host == "chat",
                  let id = Int64(url.lastPathComponent) else { return .handled }
            let chat = (telegramService.chats + telegramService.visibleChats)
                .first { $0.id == id }
            if let chat {
                // The canonical open flow (same as the launcher rows):
                // resolve username/phone hints first — a bare user_id deep
                // link is unreliable across Telegram clients — and fall
                // back to opening Telegram itself if no candidate works.
                Task { @MainActor in
                    let hints = await telegramService.getDeepLinkHints(for: chat)
                    let opened = DeepLinkGenerator.openChat(
                        chat,
                        username: hints.username,
                        phoneNumber: hints.phoneNumber
                    )
                    if !opened, let fallback = URL(string: "tg://resolve?domain=telegram") {
                        _ = DeepLinkGenerator.openInTelegram(fallback)
                    }
                }
            }
            return .handled
        })
        .tint(Color.Pidgy.accent)
    }

    private func userBubble(_ turn: AskPidgyChatModel.Turn) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(turn.text)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(Color.Pidgy.fg1)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.Pidgy.accent.opacity(0.20))
                )
        }
    }

    // Background hugs the TEXT, never the row — a short answer must not
    // stretch into a full-width bar.
    private func pidgyBubble(_ turn: AskPidgyChatModel.Turn) -> some View {
        HStack {
            RevealingAnswerText(turn: turn)
                .font(.custom("Inter", size: 13))
                .foregroundStyle(turn.isError ? Color.Pidgy.warning : Color.Pidgy.fg1)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color.Pidgy.bg3)
                )
            Spacer(minLength: 60)
        }
    }

    private var thinkingBubble: some View {
        HStack {
            HStack(spacing: 9) {
                PidgyLoader(size: 17)
                Text("thinking…")
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(Color.Pidgy.fg3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.Pidgy.bg3)
            )
            Spacer(minLength: 60)
        }
    }

    /// Render the answer's inline markdown (**bold** names) while preserving
    /// line breaks; falls back to plain text if parsing fails.
    static func renderAnswerMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(s)
    }
}

/// Typewriter reveal for freshly-arrived answers (a turn created in the last
/// two seconds). Restored/old turns render instantly; markdown (bold + chat
/// links) swaps in once the reveal finishes.
private struct RevealingAnswerText: View {
    let turn: AskPidgyChatModel.Turn
    @State private var shownCount = 0
    @State private var done = false

    var body: some View {
        Group {
            if done {
                Text(AskPidgyThreadView.renderAnswerMarkdown(turn.text))
                    .textSelection(.enabled)
            } else {
                Text(String(turn.text.prefix(shownCount)))
            }
        }
        .task(id: turn.id) {
            guard Date().timeIntervalSince(turn.createdAt) < 2, !turn.isError else {
                done = true
                return
            }
            let total = turn.text.count
            let chunk = max(2, total / 50)
            while shownCount < total, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                shownCount = min(total, shownCount + chunk)
            }
            done = true
        }
    }
}
