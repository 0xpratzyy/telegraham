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

    var debugLabel: String {
        switch self {
        case .uninitialized:
            return "uninitialized"
        case .waitingForParameters:
            return "waitingForParameters"
        case .waitingForPhoneNumber:
            return "waitingForPhoneNumber"
        case .waitingForQrCode(let link):
            return "waitingForQrCode(linkLength=\(link.count))"
        case .waitingForCode(let codeInfo):
            return "waitingForCode(phoneLength=\(codeInfo?.phoneNumber.count ?? 0), timeout=\(codeInfo?.timeout ?? 0))"
        case .waitingForPassword(let hint):
            return "waitingForPassword(hintLength=\(hint?.count ?? 0))"
        case .ready:
            return "ready"
        case .loggingOut:
            return "loggingOut"
        case .closing:
            return "closing"
        case .closed:
            return "closed"
        }
    }
}

struct CodeInfo: Equatable {
    let phoneNumber: String
    let timeout: Int

    init(phoneNumber: String = "", timeout: Int = 0) {
        self.phoneNumber = phoneNumber
        self.timeout = timeout
    }
}
