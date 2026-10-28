import Foundation

enum SSHSupervisorScript {
    static func resourceURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "chostty-ssh-supervisor", withExtension: "sh")
    }
}
