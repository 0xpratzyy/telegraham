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

    /// A readable, bounded email body for the dashboard detail panel. Gmail's
    /// canonical evidence remains untouched in storage; this only removes the
    /// transport noise that made the old Evidence card look like raw HTML.
    static func compactBody(
        subject: String,
        messageText: String,
        maxCharacters: Int = 700
    ) -> String {
        var body = preview(subject: subject, messageText: messageText)
        body = body.replacingOccurrences(
            of: #"\[image:[^\]]*\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        body = body.replacingOccurrences(
            of: #"<https?://[^>]+>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        body = body.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        let footerMarkers = [
            "you received this email to let you know",
            "this email was sent to",
            "unsubscribe from these emails",
            "manage your email preferences",
            "privacy policy"
        ]
        if let footerStart = footerMarkers.compactMap({ marker in
            body.range(of: marker, options: .caseInsensitive)?.lowerBound
        }).min() {
            body = String(body[..<footerStart])
        }

        body = normalize(body)
            .replacingOccurrences(
                of: #"\s+([.,!?;:])"#,
                with: "$1",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-:·|")))
        guard !body.isEmpty else { return "Open the original message in Gmail to read the full email." }
        guard maxCharacters > 0, body.count > maxCharacters else { return body }

        let cutoff = body.index(body.startIndex, offsetBy: maxCharacters)
        let prefix = String(body[..<cutoff])
        let clipped: String
        if body[cutoff].isWhitespace {
            clipped = prefix
        } else {
            clipped = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
        }
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
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

/// Product-level Gmail gate. Pidgy is not an inbox mirror: an email is
/// eligible for proactive surfaces only when extraction found a real reply or
/// task loop, and known machine noise is rejected even if a model overreacts.
/// Canonical mail remains stored locally so this policy can evolve without
/// deleting user data.
enum GmailEligibilityPolicy {
    static func shouldSurface(
        subject: String,
        sender: String?,
        body: String,
        hasActionableLoop: Bool
    ) -> Bool {
        hasActionableLoop && !isHardNoise(subject: subject, sender: sender, body: body)
    }

    static func isHardNoise(subject: String, sender: String?, body: String) -> Bool {
        let subjectText = normalize(subject)
        let bodyText = normalize(body)
        let combined = "\(subjectText) \(bodyText)"

        if authenticationPatterns.contains(where: { matches($0, in: combined) }) {
            return true
        }

        if marketingSubjectPatterns.contains(where: { matches($0, in: subjectText) }) {
            return true
        }

        let marketingHits = marketingBodyMarkers.reduce(into: 0) { count, marker in
            if combined.contains(marker) { count += 1 }
        }
        let senderText = normalize(sender ?? "")
        let bulkSender = senderText.contains("newsletter@")
            || senderText.contains("marketing@")
            || senderText.contains("promotions@")
        let hasStrongTaskSignal = strongTaskPatterns.contains {
            matches($0, in: combined)
        }
        return bulkSender || (marketingHits >= 2 && !hasStrongTaskSignal)
    }

    /// Rejects bad Gmail facts after model parsing and before persistence.
    /// The cited message is authoritative; fall back to the draft evidence for
    /// older providers that omit or mis-anchor a source message id.
    static func eligibleDrafts(
        _ drafts: [FactDraft],
        messages: [TGMessage],
        chat: TGChat
    ) -> [FactDraft] {
        let messagesByID = Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        return drafts.filter { draft in
            let message = messagesByID[draft.sourceMessageId]
            let body = message?.textContent ?? draft.sourceText
            let sender = message?.senderName ?? draft.senderName
            return !isHardNoise(subject: chat.title, sender: sender, body: body)
        }
    }

    private static let authenticationPatterns = [
        #"\b(otp|one[- ]time (password|passcode)|verification|security|authentication|login|sign[- ]?in) code\b"#,
        #"\b(new|recent|unrecognized|suspicious) (sign[- ]?in|login|account activity)\b"#,
        #"\bsecurity alert\b"#,
        #"\blogin activity\b"#,
        #"\bpassword reset\b"#,
        #"\bconfirm (it'?s|this is) you\b"#,
        #"\baccount recovery\b"#,
        #"\bcode (expires|will expire) in \d+ minutes?\b"#
    ]

    private static let marketingSubjectPatterns = [
        #"\b(newsletter|weekly digest|daily digest|monthly digest)\b"#,
        #"\b(sale|special offer|limited[- ]time offer|promo code|new arrivals)\b"#,
        #"\b\d{1,3}% off\b"#,
        #"\b(marketing|product) update\b"#
    ]

    private static let marketingBodyMarkers = [
        "unsubscribe",
        "manage preferences",
        "email preferences",
        "view in browser",
        "shop now",
        "limited time",
        "promo code",
        "follow us on",
        "you are receiving this because",
        "you're receiving this because"
    ]

    private static let strongTaskPatterns = [
        #"\baction required\b"#,
        #"\bplease (complete|submit|sign|review|approve|pay|provide|upload|fill out)\b"#,
        #"\b(you must|required to) (complete|submit|sign|review|approve|pay|provide|upload|fill out)\b"#,
        #"\b(due|deadline) (on|by|before)\b"#
    ]

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
