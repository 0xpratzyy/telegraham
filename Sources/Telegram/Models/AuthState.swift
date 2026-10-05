import Foundation

enum AuthState: Equatable {
    case uninitialized
    case waitingForParameters
    case waitingForPhoneNumber
    case waitingForQrCode(link: String)
    case waitingForCode(codeInfo: CodeInfo?)
    case waitingForPassword(hint: String?)
    case ready
    case loggingOut
    case closing
    case closed
}

struct CodeInfo: Equatable {
    let phoneNumber: String
    let timeout: Int
    let canResend: Bool

    init(phoneNumber: String = "", timeout: Int = 0, canResend: Bool = false) {
        self.phoneNumber = phoneNumber
        self.timeout = timeout
        self.canResend = canResend
    }
}
