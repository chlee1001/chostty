import Foundation

enum SSHAskpassEntry {
    static func isHelperInvocation(arguments: [String], environment: [String: String]) -> Bool {
        let isHelper = environment["CHOSTTY_ASKPASS_TOKEN"] != nil &&
            environment["CHOSTTY_ASKPASS_SOCKET"] != nil &&
            arguments.count == 2 &&
            !arguments[1].hasPrefix("+")
        if isHelper {
            SSHLog.askpass.notice("askpass.entry kind=helper")
        }
        return isHelper
    }
}
