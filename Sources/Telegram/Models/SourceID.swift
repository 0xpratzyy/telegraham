import Foundation

/// Identifies a *single connected account* — not just a provider.
///
/// Phase 1 tagged every chat / message with a `MessageSourceKind`, which
/// is enough to tell Telegram from Slack but not enough once a user
/// connects *two accounts of the same provider* — two Slack workspaces,
/// a work + personal Gmail. `SourceID` pairs the `kind` with a stable
/// per-account `account` string so the registry can route history
/// fetches, attribute "is this mine?", and badge rows to the right
/// account instead of collapsing them by provider.
///
/// ## Wire format (and why an empty account == the bare kind)
/// `rawValue` is `"<kind>"` when `account` is empty and
/// `"<kind>:<account>"` otherwise. The empty-account case deliberately
/// collapses to just `"telegram"` so every pre-existing
/// `messages.source = 'telegram'` row, `id_map` entry, and
/// `TGChat(… source: .telegram)` call site keeps working with **no
/// migration** — only multi-account sources ever carry a suffix.
struct SourceID: Hashable, Sendable, CustomStringConvertible, Codable {
    let kind: MessageSourceKind

    /// Which account of `kind` this is. Empty for a provider's single /
    /// primary account (always the case for Telegram today). Slack uses
    /// the workspace/team id ("T01234"); Gmail uses the address.
    let account: String

    init(kind: MessageSourceKind, account: String = "") {
        self.kind = kind
        self.account = account
    }

    /// The single Telegram account. Account is empty, so it serializes to
    /// the legacy bare `"telegram"` string.
    static let telegram = SourceID(kind: .telegram, account: "")

    /// Persisted / wire string: `"telegram"`, `"slack:T01234"`, …
    var rawValue: String {
        account.isEmpty ? kind.rawValue : "\(kind.rawValue):\(account)"
    }

    /// Parse a `rawValue`, tolerating the legacy bare-kind form. Returns
    /// nil only when the kind segment isn't a known `MessageSourceKind`.
    /// Splits on the first ":" only — Slack ids and Gmail addresses don't
    /// contain one, but this stays correct if an account ever does.
    init?(rawValue: String) {
        if let colon = rawValue.firstIndex(of: ":") {
            guard let kind = MessageSourceKind(rawValue: String(rawValue[..<colon])) else { return nil }
            self.kind = kind
            self.account = String(rawValue[rawValue.index(after: colon)...])
        } else {
            guard let kind = MessageSourceKind(rawValue: rawValue) else { return nil }
            self.kind = kind
            self.account = ""
        }
    }

    var description: String { rawValue }

    // Encoded as the flat `rawValue` string (not a {kind, account}
    // object) so JSON and DB columns stay legible and legacy-compatible.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = SourceID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown SourceID raw value \"\(raw)\""
            ))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
