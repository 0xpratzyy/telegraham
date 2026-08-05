import Foundation

/// Identifies one connected account, not merely its provider.
struct SourceID: Hashable, Sendable, CustomStringConvertible, Codable {
    let kind: MessageSourceKind
    let account: String

    init(kind: MessageSourceKind, account: String = "") {
        self.kind = kind
        self.account = account
    }

    static let telegram = SourceID(kind: .telegram)

    var rawValue: String {
        account.isEmpty ? kind.rawValue : "\(kind.rawValue):\(account)"
    }

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
