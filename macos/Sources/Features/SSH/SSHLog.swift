import Foundation
import OSLog

enum SSHLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "kr.co.devch.chostty"
    static let logger = Logger(subsystem: subsystem, category: "ssh")
    static let askpass = Logger(subsystem: subsystem, category: "ssh-askpass")
    static let tunnel = Logger(subsystem: subsystem, category: "ssh-tunnel")
}
