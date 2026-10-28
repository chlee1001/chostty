import Foundation
import Testing
@testable import Ghostty

@MainActor
struct SSHQuickConnectModelTests {
    private func host(
        _ alias: String,
        siblingAliases: [String] = [],
        displayName: String? = nil,
        destination: SSHResolvedDestination? = nil
    ) -> SSHHostEntry {
        SSHHostEntry(
            reference: SSHHostReference(source: .sshConfig, alias: alias),
            definedIn: URL(fileURLWithPath: "/tmp/config"),
            line: 1,
            siblingAliases: siblingAliases,
            displayName: displayName,
            isFavorite: false,
            resolved: destination)
    }

    @Test func filtersAliasesDisplayNamesAndResolvedDestinations() {
        let prod = host(
            "prod-api",
            siblingAliases: ["production"],
            displayName: "Production API",
            destination: SSHResolvedDestination(user: "deploy", hostName: "api.example.com", port: 2201))
        let staging = host("staging")
        let model = SSHQuickConnectModel(hosts: [prod, staging])

        model.query = "production"
        #expect(model.entries == [prod])
        model.query = "Production API"
        #expect(model.entries == [prod])
        model.query = "deploy@api.example.com:2201"
        #expect(model.entries == [prod])
    }

    @Test func selectionClampsAtBoundariesAndIsEmptyWithoutMatches() {
        let prod = host("prod")
        let staging = host("staging")
        let model = SSHQuickConnectModel(hosts: [prod, staging])

        #expect(model.selectedIndex == 0)
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 0)
        model.moveSelection(by: 10)
        #expect(model.selectedIndex == 1)
        model.query = "missing"
        #expect(model.selectedIndex == nil)
        #expect(model.action(connectInSplit: false) == nil)
    }

    @Test func returnActionsUseTheSelectedCatalogReference() {
        let prod = host("prod")
        let staging = host("staging")
        let model = SSHQuickConnectModel(hosts: [prod, staging])

        model.moveSelection(by: 1)
        #expect(model.action(connectInSplit: false) == .connect(staging.reference))
        #expect(model.action(connectInSplit: true) == .connectInSplit(staging.reference))
    }

    @Test func arbitraryDestinationsNeverCreateRows() {
        let model = SSHQuickConnectModel(hosts: [host("prod")])

        model.query = "deploy@10.0.0.5"

        #expect(model.entries.isEmpty)
        #expect(model.selectedEntry == nil)
    }

    @Test func recentsAreMostRecentFirstAndUnavailableReferencesAreSkipped() {
        let prod = host("prod")
        let staging = host("staging")
        let unavailable = SSHHostReference(source: .sshConfig, alias: "removed")
        let model = SSHQuickConnectModel(
            hosts: [prod, staging],
            recentReferences: [staging.reference, unavailable, prod.reference])

        #expect(model.entries.map(\.reference) == [staging.reference, prod.reference])

        model.updateHosts([prod])

        #expect(model.entries == [prod])
    }
}
