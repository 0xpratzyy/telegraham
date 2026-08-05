import Foundation

struct WhatsAppImport: Sendable, Equatable {
    let conversation: CanonicalConversation
    let messages: [CanonicalMessage]
}

enum WhatsAppExportParser {
    static func parse(
        _ text: String,
        fileName: String,
        ownerName: String? = nil,
        importedAt: Date = Date()
    ) throws -> WhatsAppImport {
        let title = fileName
            .replacingOccurrences(of: "WhatsApp Chat with ", with: "")
            .replacingOccurrences(of: ".txt", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let externalID = CanonicalID.legacyInt64("whatsapp|\(fileName)|\(text.prefix(256))").description
        let accountID = CanonicalID.account(source: .whatsapp, externalID: "manual-import")
        let conversationID = CanonicalID.conversation(
            source: .whatsapp,
            accountID: accountID,
            externalID: externalID
        )
        let conversation = CanonicalConversation(
            id: conversationID,
            accountID: accountID,
            source: .whatsapp,
            externalID: externalID,
            kind: .importedChat,
            title: title.isEmpty ? "WhatsApp import" : title,
            updatedAt: importedAt
        )

        var parsed: [ParsedLine] = []
        for line in text.components(separatedBy: .newlines) {
            if let newMessage = parseLine(line) {
                parsed.append(newMessage)
            } else if !line.isEmpty, !parsed.isEmpty {
                parsed[parsed.count - 1].text += "\n" + line
            }
        }
        guard !parsed.isEmpty else {
            throw SourceAdapterError.unsupported("No WhatsApp messages were found in this export.")
        }

        let normalizedOwner = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let messages = parsed.enumerated().map { index, item in
            let externalMessageID = "\(Int(item.date.timeIntervalSince1970)):\(index)"
            return CanonicalMessage(
                id: CanonicalID.message(
                    source: .whatsapp,
                    conversationID: conversationID,
                    externalID: externalMessageID
                ),
                conversationID: conversationID,
                source: .whatsapp,
                externalID: externalMessageID,
                threadRootID: nil,
                senderExternalID: item.sender.lowercased(),
                senderName: item.sender,
                subject: nil,
                date: item.date,
                text: item.text,
                isOutgoing: normalizedOwner.map { item.sender.lowercased() == $0 } ?? false
            )
        }
        return WhatsAppImport(conversation: conversation, messages: messages)
    }

    private struct ParsedLine {
        let date: Date
        let sender: String
        var text: String
    }

    private static func parseLine(_ line: String) -> ParsedLine? {
        let patterns = [
            #"^\[(\d{1,2}/\d{1,2}/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APap][Mm])?)\]\s+([^:]+):\s?(.*)$"#,
            #"^(\d{1,2}/\d{1,2}/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APap][Mm])?)\s+-\s+([^:]+):\s?(.*)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges == 5,
                  let dateRange = Range(match.range(at: 1), in: line),
                  let timeRange = Range(match.range(at: 2), in: line),
                  let senderRange = Range(match.range(at: 3), in: line),
                  let textRange = Range(match.range(at: 4), in: line),
                  let date = parseDate("\(line[dateRange]) \(line[timeRange])") else { continue }
            return ParsedLine(
                date: date,
                sender: String(line[senderRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                text: String(line[textRange])
            )
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let formats = [
            "d/M/yyyy H:mm:ss", "d/M/yyyy H:mm", "d/M/yy H:mm:ss", "d/M/yy H:mm",
            "M/d/yyyy h:mm:ss a", "M/d/yyyy h:mm a", "M/d/yy h:mm:ss a", "M/d/yy h:mm a"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
