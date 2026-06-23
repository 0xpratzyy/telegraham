import Foundation

/// The "how this human writes" layer of Pidgy's context store. Builds a short
/// voice profile from the user's own outgoing messages and caches it as a
/// human-readable, user-editable markdown file at
/// `~/Library/Application Support/Pidgy/context/voice.md`. Style only — never
/// the private content of messages (see VoiceProfilePrompt). Phase 1: generate
/// + persist. Phase 2 will inject this into the reply/draft prompts.
actor VoiceProfileService {
    static let shared = VoiceProfileService()

    private let sampleSize = 120
    private let minMessages = 15
    /// Voice drifts slowly — only re-generate after this many new outgoing
    /// messages since the last build, so we don't burn AI calls.
    private let staleGrowthCount = 200

    private var contextDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("context", isDirectory: true)
    }
    private var fileURL: URL { contextDir.appendingPathComponent("voice.md") }
    private var stateURL: URL { contextDir.appendingPathComponent(".voice_state.json") }

    /// The cached profile text, if one has been generated.
    func currentProfile() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// On-disk location of the editable profile, for "reveal in Finder".
    nonisolated var profileFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
            .appendingPathComponent("context", isDirectory: true)
            .appendingPathComponent("voice.md")
    }

    /// Persist a user-edited profile. Hand edits are respected as-is — we
    /// only re-generate when the user explicitly asks (the Preferences
    /// "Regenerate" button) or, automatically, when no file exists yet.
    func saveProfile(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Generate on first run, then only when enough new outgoing messages have
    /// accrued. Safe to call on every launch — cheap when nothing's due.
    func refreshIfNeeded(aiService: AIService) async {
        guard await aiService.isConfigured else { return }
        let liveCount = await DatabaseManager.shared.outgoingMessageCount()
        guard liveCount >= minMessages else { return }

        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let lastBuiltAt = loadLastBuiltCount()
        guard !exists || (liveCount - lastBuiltAt) >= staleGrowthCount else { return }

        await generate(aiService: aiService, liveCount: liveCount)
    }

    /// Force a rebuild (e.g. a "Refresh voice profile" button).
    func generate(aiService: AIService, liveCount: Int? = nil) async {
        let count: Int
        if let liveCount {
            count = liveCount
        } else {
            count = await DatabaseManager.shared.outgoingMessageCount()
        }
        let messages = await DatabaseManager.shared.loadRecentOutgoingMessages(limit: sampleSize)
        guard messages.count >= minMessages else { return }

        guard let profile = try? await aiService.extractVoiceProfile(outgoingMessages: messages),
              !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile != "Not enough messages yet." else { return }

        try? FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true)
        try? profile.write(to: fileURL, atomically: true, encoding: .utf8)
        saveLastBuiltCount(count)
    }

    private func loadLastBuiltCount() -> Int {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode([String: Int].self, from: data) else { return 0 }
        return state["outgoingCount"] ?? 0
    }

    private func saveLastBuiltCount(_ count: Int) {
        if let data = try? JSONEncoder().encode(["outgoingCount": count]) {
            try? data.write(to: stateURL)
        }
    }
}
