import Foundation
import Testing
@testable import Ghostty

struct SSHDuplicateToEditTests {
    @Test func copiesSupportedOptionDifferencesToANewHost() async throws {
        let resolver = DuplicateFakeResolver(
            original: result(
                user: "deploy",
                host: "api.example.test",
                port: 2201,
                options: [
                    "user": ["deploy"],
                    "port": ["2201"],
                    "identityfile": ["~/.ssh/deploy", "/etc/ssh/backup"],
                    "proxyjump": ["bastion"],
                    "identitiesonly": ["yes"],
                    "forwardagent": ["no"],
                    "serveraliveinterval": ["30"],
                    "compression": ["yes"],
                ]),
            baseline: result(
                user: "local",
                host: "api.example.test",
                port: 22,
                options: [
                    "user": ["local"],
                    "port": ["22"],
                    "identityfile": [],
                    "proxyjump": ["none"],
                    "identitiesonly": ["no"],
                    "forwardagent": ["no"],
                    "serveraliveinterval": ["0"],
                    "compression": ["no"],
                ]))
        let duplicate = SSHDuplicateToEdit(resolver: resolver)
        let paths = testPaths()
        let originalID = UUID()
        let reference = SSHHostReference(source: .managed(hostID: originalID), alias: "api")

        let copied = await duplicateResult(
            duplicate,
            reference: reference,
            paths: paths,
            alias: "api-copy")
        let result = try copied.get()

        #expect(result.host.hostID != originalID)
        #expect(result.host.alias == "api-copy")
        #expect(result.host.hostName == "api.example.test")
        #expect(result.host.user == "deploy")
        #expect(result.host.port == 2201)
        #expect(result.host.identityFiles == ["~/.ssh/deploy", "/etc/ssh/backup"])
        #expect(result.host.proxyJump == "bastion")
        #expect(result.host.identitiesOnly == true)
        #expect(result.host.forwardAgent == nil)
        #expect(result.host.serverAliveInterval == 30)
        #expect(result.notCopied == ["compression"])
        #expect(resolver.resolveCount == 1)
        #expect(resolver.baselineCount == 1)
    }

    @Test func rejectsInvalidOrOriginalAliasWithoutResolving() async {
        let resolver = DuplicateFakeResolver(original: result(), baseline: result())
        let duplicate = SSHDuplicateToEdit(resolver: resolver)
        let reference = SSHHostReference(source: .sshConfig, alias: "original")

        let invalid = await duplicateResult(duplicate, reference: reference, paths: testPaths(), alias: "bad alias")
        let same = await duplicateResult(duplicate, reference: reference, paths: testPaths(), alias: "original")

        #expect(invalid == .failure(.invalidAlias(.nonASCII)))
        #expect(same == .failure(.aliasMustDiffer))
        #expect(resolver.resolveCount == 0)
        #expect(resolver.baselineCount == 0)
    }

    @Test func refusesMatchExecWithoutConsentBeforeStartingResolution() async {
        let resolver = DuplicateFakeResolver(original: result(), baseline: result())
        let duplicate = SSHDuplicateToEdit(resolver: resolver)
        let reference = SSHHostReference(source: .sshConfig, alias: "source")

        let copied = await duplicateResult(
            duplicate,
            reference: reference,
            paths: testPaths(),
            containsMatchExec: true,
            alias: "copy")

        #expect(copied == .failure(.matchExecConsentRequired))
        #expect(resolver.resolveCount == 0)
        #expect(resolver.baselineCount == 0)
    }
}

private final class DuplicateFakeResolver: SSHResolving, @unchecked Sendable {
    let original: SSHResolver.Result?
    let baseline: SSHResolver.Result?
    private(set) var resolveCount = 0
    private(set) var baselineCount = 0

    init(original: SSHResolver.Result?, baseline: SSHResolver.Result?) {
        self.original = original
        self.baseline = baseline
    }

    func resolve(
        reference: SSHHostReference,
        paths: SSHPaths,
        observations: [String: SSHFileObservation],
        containsMatchExec: Bool,
        reason: SSHResolver.Reason,
        completion: @escaping @Sendable (SSHResolver.Result?) -> Void
    ) {
        resolveCount += 1
        completion(original)
    }

    func resolveBaseline(alias: String, completion: @escaping @Sendable (SSHResolver.Result?) -> Void) {
        baselineCount += 1
        completion(baseline)
    }
}

private func duplicateResult(
    _ duplicate: SSHDuplicateToEdit,
    reference: SSHHostReference,
    paths: SSHPaths,
    containsMatchExec: Bool = false,
    alias: String
) async -> Swift.Result<SSHDuplicateToEditResult, SSHDuplicateToEditError> {
    await withCheckedContinuation { continuation in
        duplicate.duplicate(
            reference: reference,
            paths: paths,
            observations: [:],
            containsMatchExec: containsMatchExec,
            alias: alias,
            completion: { value in continuation.resume(returning: value) })
    }
}

private func result(
    user: String = "user",
    host: String = "host.example.test",
    port: Int = 22,
    options: [String: [String]] = [:]
) -> SSHResolver.Result {
    SSHResolver.Result(
        destination: SSHResolvedDestination(user: user, hostName: host, port: port),
        options: options)
}

private func testPaths() -> SSHPaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return SSHPaths(home: root, runtimeRoot: root.appendingPathComponent("runtime"))
}
