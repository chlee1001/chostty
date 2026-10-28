import Testing
@testable import Ghostty

struct SSHAliasTests {
    @Test func acceptsConcreteHostAliases() throws {
        #expect(try SSHAlias.validate("prod-api").get() == "prod-api")
        #expect(try SSHAlias.validate("build_01.example").get() == "build_01.example")
        #expect(try SSHAlias.validate(String(repeating: "a", count: 255)).get().utf8.count == 255)
    }

    @Test func rejectsEveryForbiddenAliasForm() {
        let cases = [
            "",
            "-option",
            "host name",
            "host\tname",
            "host\nname",
            "host\u{1B}name",
            "host*",
            "host?",
            "host!",
            "host,name",
            "host'",
            "host\"",
            "host\\name",
            "host$name",
            "host;name",
            "host|name",
            "host&name",
            "host<name",
            "host>name",
            "host(name",
            "host)name",
            "host`name",
            "host%name",
            String(repeating: "a", count: 256),
            "é"
        ]
        for alias in cases {
            switch SSHAlias.validate(alias) {
            case .success:
                Issue.record("unexpectedly accepted \(alias)")
            case .failure:
                break
            }
        }
    }
}
