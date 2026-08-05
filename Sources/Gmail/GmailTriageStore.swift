import Foundation

enum GmailTriageState: String, Codable, CaseIterable, Sendable {
    case inbox
    case needsReply = "needs_reply"
    case waiting
    case later
    case done
}

enum GmailInboxClassifier {
    static func isNewsletter(sender: String, subject: String, body: String) -> Bool {
        let sender = sender.lowercased()
        let subject = subject.lowercased()
        let body = body.lowercased()
        let senderSignals = ["noreply", "no-reply", "newsletter", "updates@", "marketing@", "digest@"]
        let subjectSignals = ["newsletter", "digest", "weekly", "unsubscribe", "roundup"]
        return senderSignals.contains(where: sender.contains)
            || subjectSignals.contains(where: subject.contains)
            || body.contains("unsubscribe")
    }
}

struct GmailThreadTriage: Equatable, Sendable {
    let chatID: Int64
    var state: GmailTriageState
    var snoozedUntil: Date?
    var updatedAt: Date

    static func inbox(chatID: Int64) -> GmailThreadTriage {
        GmailThreadTriage(chatID: chatID, state: .inbox, snoozedUntil: nil, updatedAt: .distantPast)
    }
}

@MainActor
final class GmailTriageStore: ObservableObject {
    struct UndoAction: Equatable {
        let chatID: Int64
        let previous: GmailThreadTriage
        let message: String
    }

    static let shared = GmailTriageStore()

    @Published private(set) var states: [Int64: GmailThreadTriage] = [:]
    @Published private(set) var undoAction: UndoAction?
    private var hasLoaded = false

    private init() {}

    func load() async {
        guard !hasLoaded else { return }
        states = await DatabaseManager.shared.loadGmailThreadTriage()
        hasLoaded = true
    }

    func state(for chatID: Int64, now: Date = Date()) -> GmailThreadTriage {
        guard var stored = states[chatID] else { return .inbox(chatID: chatID) }
        if stored.state == .later, let snoozedUntil = stored.snoozedUntil, snoozedUntil <= now {
            stored.state = .inbox
            stored.snoozedUntil = nil
        }
        return stored
    }

    func set(_ newState: GmailTriageState, for chatID: Int64, snoozedUntil: Date? = nil) async {
        let previous = state(for: chatID)
        let updated = GmailThreadTriage(
            chatID: chatID,
            state: newState,
            snoozedUntil: newState == .later ? snoozedUntil : nil,
            updatedAt: Date()
        )
        states[chatID] = updated
        undoAction = UndoAction(chatID: chatID, previous: previous, message: Self.feedback(for: newState))
        do {
            try await DatabaseManager.shared.saveGmailThreadTriage(updated)
        } catch {
            states[chatID] = previous
            undoAction = nil
        }
    }

    func undo() async {
        guard let action = undoAction else { return }
        states[action.chatID] = action.previous
        undoAction = nil
        try? await DatabaseManager.shared.saveGmailThreadTriage(action.previous)
    }

    func dismissUndo() {
        undoAction = nil
    }

    private static func feedback(for state: GmailTriageState) -> String {
        switch state {
        case .inbox: return "Moved to Focused"
        case .needsReply: return "Added to Needs Reply"
        case .waiting: return "Marked as Waiting"
        case .later: return "Remind tomorrow"
        case .done: return "Marked Done"
        }
    }
}
