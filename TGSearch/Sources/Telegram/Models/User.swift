import Foundation

struct TGUser: Identifiable, Equatable {
    let id: Int64
    let firstName: String
    let lastName: String
    let username: String?
    let phoneNumber: String?

    var displayName: String {
        let full = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? (username ?? "Unknown") : full
    }

    var initials: String {
        let first = firstName.prefix(1)
        let last = lastName.prefix(1)
        let result = "\(first)\(last)".trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "?" : result.uppercased()
    }
}
