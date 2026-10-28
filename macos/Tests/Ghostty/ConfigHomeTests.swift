import Foundation
import Testing
@testable import Ghostty

struct ConfigHomeTests {
    @Test("uses a non-empty XDG_CONFIG_HOME")
    func usesNonEmptyXDGConfigHome() {
        #expect(ConfigHome.directory(environment: ["XDG_CONFIG_HOME": "/tmp/config-home"]).path == "/tmp/config-home")
    }

    @Test("empty and unset XDG_CONFIG_HOME use the default")
    func usesDefaultForEmptyAndUnsetXDGConfigHome() {
        #expect(ConfigHome.directory(environment: ["XDG_CONFIG_HOME": ""]).lastPathComponent == ".config")
        #expect(ConfigHome.directory(environment: [:]).lastPathComponent == ".config")
        let home = URL(fileURLWithPath: "/tmp/fixture-home", isDirectory: true)
        #expect(ConfigHome.directory(environment: ["XDG_CONFIG_HOME": ""], home: home).path == "/tmp/fixture-home/.config")
    }

    @Test("the first theme directory is under the config home")
    func themeCatalogUsesConfigHomeFirst() {
        let directories = ThemeCatalog.directories(environment: ["XDG_CONFIG_HOME": "/tmp/config-home"])
        #expect(directories.first?.url.path == "/tmp/config-home/ghostty/themes")
        #expect(directories.first?.isUser == true)
    }
}
