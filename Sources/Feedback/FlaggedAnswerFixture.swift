import Foundation

/// User-initiated "this answer was wrong" capture.
///
/// Privacy model: flagging NEVER sends anything by itself. It does two
/// things — (1) always writes a local fixture file (the developer's own
/// machine, raw material for refreshing the eval oracles), and (2)
/// prefills the feedback sheet with a human-readable block of exactly
/// what would be shared. The user sees the full payload in the text
/// area and can edit or delete any line before pressing Send — the
/// preview IS the consent. Nothing is attached invisibly.
struct FlaggedAnswerFixture: Codable {
    let query: String
    let route: String
    let resultTitle: String?
    let resultText: String?
    let supportingSnippets: [String]
    let capturedAt: Date
    let appVersion: String
    let commitSHA: String

    /// Caps keep the prefill comfortably inside the feedback sheet's
    /// 2000-char limit while leaving the user room to add their own
    /// note on top.
    private static let maxSnippets = 5
    private static let maxSnippetLength = 150
    private static let maxResultTextLength = 600
    private static let maxQueryLength = 200

    init(
        query: String,
        route: String,
        resultTitle: String?,
        resultText: String?,
        supportingSnippets: [String],
        capturedAt: Date = Date(),
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        commitSHA: String = BundledSecrets.buildCommitSHA
    ) {
        self.query = String(query.prefix(Self.maxQueryLength))
        self.route = route
        self.resultTitle = resultTitle
        self.resultText = resultText.map { String($0.prefix(Self.maxResultTextLength)) }
        self.supportingSnippets = supportingSnippets
            .prefix(Self.maxSnippets)
            .map { String($0.prefix(Self.maxSnippetLength)) }
        self.capturedAt = capturedAt
        self.appVersion = appVersion
        self.commitSHA = commitSHA
    }

    /// The context block shown in the feedback sheet's removable
    /// attachment panel. Everything the user would share is visible
    /// there — there is no hidden payload beyond these lines.
    func attachmentText() -> String {
        var lines: [String] = [
            "About: \(query)",
            "Route: \(route)"
        ]
        if let resultTitle, !resultTitle.isEmpty {
            lines.append("Answer title: \(resultTitle)")
        }
        if let resultText, !resultText.isEmpty {
            lines.append("Answer: \(resultText)")
        }
        if !supportingSnippets.isEmpty {
            lines.append("Shown results:")
            for snippet in supportingSnippets {
                lines.append("  • \(snippet)")
            }
        }
        lines.append("Build: \(appVersion) (\(commitSHA))")
        return lines.joined(separator: "\n")
    }

    /// Always-local fixture write — raw material for the eval oracle
    /// refresh loop. Lives inside Application Support/Pidgy, so the
    /// "Reset all local data" wipe covers it.
    @discardableResult
    func writeLocalFixture(directoryOverride: URL? = nil) throws -> URL {
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else {
            directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Pidgy", isDirectory: true)
                .appendingPathComponent("flagged", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stampFormatter = ISO8601DateFormatter()
        stampFormatter.formatOptions = [.withInternetDateTime]
        let stamp = stampFormatter.string(from: capturedAt)
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = directory.appendingPathComponent(
            "flagged-\(stamp)-\(UUID().uuidString.prefix(8)).json"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: fileURL, options: .atomic)
        return fileURL
    }
}

extension FlaggedAnswerFixture {
    /// One-stop flag action: save the local eval fixture and park the
    /// attachment for the feedback sheet (DashboardView observes the
    /// store and presents). Nothing is sent until the user presses
    /// Send in the sheet.
    @MainActor
    func submitToFeedbackSheet() {
        try? writeLocalFixture()
        FeedbackPrefillStore.shared.pending = attachmentText()
    }

    /// Flag a reply-queue triage decision (wrong category / bad
    /// suggested action).
    static func replyTriage(_ item: FollowUpItem) -> FlaggedAnswerFixture {
        FlaggedAnswerFixture(
            query: "reply-queue triage for \(item.chat.title)",
            route: "reply_queue_triage",
            resultTitle: "Categorized \(item.category.rawValue)",
            resultText: item.suggestedAction,
            supportingSnippets: [
                "\(item.chat.title) (latest): \(item.lastMessage.displayText)"
            ]
        )
    }

    /// Flag an extracted task (not a task / wrong owner / duplicate…).
    static func task(
        _ task: DashboardTask,
        evidence: [DashboardTaskSourceMessage]
    ) -> FlaggedAnswerFixture {
        FlaggedAnswerFixture(
            query: "task extraction in \(task.chatTitle)",
            route: "task_extraction",
            resultTitle: task.title,
            resultText: "owner: \(task.ownerName) · person: \(task.personName) · status: \(task.status.rawValue) · \(task.summary)",
            supportingSnippets: evidence.prefix(3).map { "\($0.senderName): \($0.text)" }
        )
    }
}

/// Hand-off slot between the launcher's "Flag answer" affordance and the
/// dashboard's feedback sheet. The launcher can't present the sheet
/// itself (it lives on the dashboard window, which may not even be open
/// yet), so it parks the prefill here, asks AppDelegate to open the
/// dashboard, and DashboardView consumes the pending value whenever it
/// appears or changes.
@MainActor
final class FeedbackPrefillStore: ObservableObject {
    static let shared = FeedbackPrefillStore()
    @Published var pending: String?

    private init() {}

    func consume() -> String? {
        defer { pending = nil }
        return pending
    }
}
