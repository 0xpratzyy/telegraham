import Foundation

/// Display-only cleanup for Gmail records. Canonical storage deliberately
/// keeps the original RFC-style sender and subject-prefixed body as evidence;
/// dashboard surfaces should present that data like email, not leak transport
/// formatting into the UI.
enum GmailPresentation {
    static func senderName(from rawValue: String?, fallback: String = "Email sender") -> String {
        let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return fallback }

        let email = emailAddress(in: raw)
        if let angle = raw.firstIndex(of: "<") {
            let display = String(raw[..<angle])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if !display.isEmpty, !display.contains("@"), !looksLikeBareDomain(display) {
                return display
            }
        } else if !raw.contains("@") {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return email.flatMap { brandName(from: $0) } ?? fallback
    }

    static func preview(subject: String, messageText: String) -> String {
        let normalizedSubject = normalize(subject)
        let normalizedMessage = normalize(messageText)
        guard !normalizedSubject.isEmpty else { return normalizedMessage }
        guard normalizedMessage.range(
            of: normalizedSubject,
            options: [.caseInsensitive, .anchored]
        ) != nil else {
            return normalizedMessage
        }

        return String(normalizedMessage.dropFirst(normalizedSubject.count))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-:·")))
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func emailAddress(in value: String) -> String? {
        if let start = value.lastIndex(of: "<"), let end = value[start...].firstIndex(of: ">") {
            let address = String(value[value.index(after: start)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if address.contains("@") { return address.lowercased() }
        }
        let stripped = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'<>"))
        return stripped.contains("@") ? stripped.lowercased() : nil
    }

    private static func brandName(from email: String) -> String? {
        guard let domain = email.split(separator: "@").last else { return nil }
        let ignored = Set(["accounts", "app", "email", "mail", "notifications", "notify", "support"])
        let candidates = domain.split(separator: ".").dropLast().reversed()
        guard let brand = candidates.first(where: { !ignored.contains(String($0).lowercased()) }) else {
            return nil
        }
        return String(brand)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func looksLikeBareDomain(_ value: String) -> Bool {
        !value.contains(" ") && value.contains(".")
    }
}
