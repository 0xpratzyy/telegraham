import Foundation

struct TGUser: Identifiable, Equatable, Sendable {
    let id: Int64
    let firstName: String
    let lastName: String
    let username: String?
    let phoneNumber: String?
    let smallPhotoFileId: Int?
    let isBot: Bool

    init(
        id: Int64,
        firstName: String,
        lastName: String,
        username: String?,
        phoneNumber: String?,
        isBot: Bool,
        smallPhotoFileId: Int? = nil
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.username = username
        self.phoneNumber = phoneNumber
        self.isBot = isBot
        self.smallPhotoFileId = smallPhotoFileId
    }

    var displayName: String {
        let full = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? (username ?? "Unknown") : full
    }

    var displayHandle: String? {
        guard let username, !username.isEmpty else { return nil }
        return "@\(username)"
    }

    var initials: String {
        let first = firstName.prefix(1)
        let last = lastName.prefix(1)
        let result = "\(first)\(last)".trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "?" : result.uppercased()
    }
}
