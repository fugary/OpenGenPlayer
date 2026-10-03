#if os(macOS) || os(iOS) || os(tvOS)
import Foundation

/// Match AMSMB2's saved-account syntax: domain;workstation\user.
/// Keep this local to audio extraction; browsing retains its existing client.
struct SMBAudioLogin {
    let user: String
    let domain: String
    let workstation: String

    init(user input: String?) {
        var user = "guest", domain = "", workstation = ""
        if var remaining = input {
            let domainParts = remaining.components(separatedBy: ";")
            if domainParts.count == 2 {
                domain = domainParts[0]
                remaining = domainParts[1]
            }
            let userParts = remaining.components(separatedBy: "\\")
            switch userParts.count {
            case 1: user = userParts[0]
            case 2: workstation = userParts[0]; user = userParts[1]
            default: break
            }
        }
        self.user = user
        self.domain = domain
        self.workstation = workstation
    }
}
#endif
