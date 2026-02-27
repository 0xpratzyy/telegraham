import Foundation

enum AuthState: Equatable {
    case uninitialized
    case waitingForParameters
    case waitingForPhoneNumber
    case waitingForCode(codeInfo: CodeInfo?)
    case waitingForPassword(hint: String?)
    case waitingForRegistration
    case ready
    case loggingOut
    case closing
    case closed
}

struct CodeInfo: Equatable {
    let phoneNumber: String
    let timeout: Int

    init(phoneNumber: String = "", timeout: Int = 0) {
        self.phoneNumber = phoneNumber
        self.timeout = timeout
    }
}
