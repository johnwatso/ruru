import Foundation
import XCTest
import WitnessKit

final class WitnessConfigurationTests: XCTestCase {
    func testPrimaryPreferencePersistsPerServiceAndClearingAdvancesRevision() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruPrimaryPreference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var configuration = WitnessConfiguration()
        let worker = GuardedService(name: "Worker", clusterID: "worker")
        configuration.additionalServices = [worker]
        XCTAssertTrue(try configuration.setPreferredPrimary("primary-a", for: "swiftbot"))
        XCTAssertTrue(try configuration.setPreferredPrimary("worker-b", for: worker.id))
        XCTAssertFalse(try configuration.setPreferredPrimary("primary-a", for: "swiftbot"))
        try WitnessStorage.save(configuration, in: folder)
        var restored = try WitnessStorage.load(from: folder)
        XCTAssertEqual(restored.primaryPreference(for: "swiftbot").preferredPrimaryNodeID, "primary-a")
        XCTAssertEqual(restored.primaryPreference(for: worker.id).preferredPrimaryNodeID, "worker-b")
        XCTAssertEqual(restored.primaryPreference(for: "swiftbot").revision, 1)
        XCTAssertTrue(try restored.setPreferredPrimary(nil, for: "swiftbot"))
        try WitnessStorage.save(restored, in: folder)
        let cleared = try WitnessStorage.load(from: folder)
        XCTAssertNil(cleared.primaryPreference(for: "swiftbot").preferredPrimaryNodeID)
        XCTAssertEqual(cleared.primaryPreference(for: "swiftbot").revision, 2)
        XCTAssertEqual(cleared.primaryPreference(for: worker.id).revision, 1)
        XCTAssertEqual(cleared.clusterID, configuration.clusterID)
        XCTAssertEqual(cleared.tunnel, configuration.tunnel)
    }

    func testPreferenceRejectsInvalidIDsAndRemovedServicesCannotInheritPreferences() throws {
        var configuration = WitnessConfiguration()
        for invalid in ["", "  node", "node\n", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try configuration.setPreferredPrimary(invalid, for: "swiftbot"))
        }
        XCTAssertThrowsError(try configuration.setPreferredPrimary("node", for: "missing"))
        try configuration.setPreferredPrimary("node-a", for: "swiftbot")
        try configuration.removeGuardedService(id: "swiftbot")
        XCTAssertTrue(configuration.servicePrimaryPreferences.isEmpty)
        let replacement = GuardedService(name: "Replacement", clusterID: configuration.clusterID)
        configuration.additionalServices = [replacement]
        XCTAssertNil(configuration.primaryPreference(for: replacement.id).preferredPrimaryNodeID)
        XCTAssertEqual(configuration.primaryPreference(for: replacement.id).revision, 0)
        configuration.servicePrimaryPreferences["missing"] = .init(preferredPrimaryNodeID: "node")
        XCTAssertFalse(configuration.isValid)
    }

    func testPreferenceRevisionExhaustionFailsWithoutChangingSelection() throws {
        var configuration = WitnessConfiguration()
        configuration.servicePrimaryPreferences["swiftbot"] = .init(preferredPrimaryNodeID: "node-a", revision: Int64.max)
        XCTAssertThrowsError(try configuration.setPreferredPrimary("node-b", for: "swiftbot"))
        XCTAssertEqual(configuration.primaryPreference(for: "swiftbot").preferredPrimaryNodeID, "node-a")
        configuration.servicePrimaryPreferences["swiftbot"] = .init(revision: -1)
        XCTAssertFalse(configuration.isValid)
    }

    func testLegacySettingsRetainTheirValuesWithoutEnablingInternetAccess() throws {
        let data = Data(#"{"clusterID":"my-cluster","bindAddress":"127.0.0.1","port":38990,"publicEndpoint":"https://witness.example.com","startAutomatically":false}"#.utf8)
        let configuration = try JSONDecoder().decode(WitnessConfiguration.self, from: data)
        XCTAssertEqual(configuration.clusterID, "my-cluster")
        XCTAssertFalse(configuration.startAutomatically)
        XCTAssertFalse(configuration.showInDock)
        XCTAssertFalse(configuration.primaryServiceRemoved)
        XCTAssertFalse(configuration.tunnel.enabled)
        XCTAssertFalse(configuration.tunnel.isConfigured)
        XCTAssertTrue(configuration.isValid)
        XCTAssertTrue(configuration.nodeDisplayNames.isEmpty)
        XCTAssertTrue(configuration.servicePrimaryPreferences.isEmpty)
        let restored = try JSONDecoder().decode(WitnessConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.tunnel.instanceID, configuration.tunnel.instanceID)
    }

    func testMissingRequiredSettingsAreNotSilentlyReplaced() {
        XCTAssertThrowsError(try JSONDecoder().decode(WitnessConfiguration.self, from: Data("{}".utf8)))
    }

    func testRemovingPrimaryAndAdditionalServicesSurvivesRestartAndAllowsAnEmptyCatalog() throws {
        var configuration = WitnessConfiguration()
        let worker = GuardedService(name: "Worker", clusterID: "worker")
        configuration.additionalServices = [worker]
        configuration.showInDock = true
        try configuration.removeGuardedService(id: "swiftbot")
        XCTAssertEqual(configuration.guardedServices, [worker])
        XCTAssertTrue(configuration.isValid)
        let restored = try JSONDecoder().decode(WitnessConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.guardedServices, [worker])
        XCTAssertTrue(restored.showInDock)
        try configuration.removeGuardedService(id: worker.id)
        XCTAssertTrue(configuration.guardedServices.isEmpty)
        XCTAssertTrue(configuration.isValid)
        let empty = try JSONDecoder().decode(WitnessConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertTrue(empty.guardedServices.isEmpty)
        XCTAssertThrowsError(try configuration.removeGuardedService(id: "missing"))
    }

    func testNewServiceCanReuseRemovedGroupWithoutResurrectingPrimaryCredential() throws {
        var configuration = WitnessConfiguration()
        try configuration.removeGuardedService(id: "swiftbot")
        let replacement = GuardedService(name: "Replacement", clusterID: configuration.clusterID, kind: .swiftBot)
        configuration.additionalServices = [replacement]
        XCTAssertTrue(configuration.isValid)
        XCTAssertNotEqual(replacement.keychainAccount, "authority-bearer-token")
        configuration.additionalServices[0].id = "swiftbot"
        XCTAssertFalse(configuration.isValid)
    }

    func testSavedBotNamesRoundTripByStableNodeID() throws {
        var configuration = WitnessConfiguration()
        configuration.nodeDisplayNames = ["primary-id": "Primary Mac", "backup-id": "Failover Mac"]
        XCTAssertTrue(configuration.isValid)
        let restored = try JSONDecoder().decode(WitnessConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.nodeDisplayNames, configuration.nodeDisplayNames)
        XCTAssertEqual(restored.clusterID, configuration.clusterID)
        XCTAssertEqual(restored.tunnel, configuration.tunnel)
    }

    func testLegacySettingsBecomeSwiftBotServiceWithoutChangingIdentity() throws {
        let data = Data(#"{"clusterID":"existing","bindAddress":"127.0.0.1","port":38990,"publicEndpoint":"","startAutomatically":false,"nodeDisplayNames":{"server":"Primary Mac"}}"#.utf8)
        let configuration = try JSONDecoder().decode(WitnessConfiguration.self, from: data)
        let service = try XCTUnwrap(configuration.guardedServices.first)
        XCTAssertEqual(service.name, "SwiftBot")
        XCTAssertEqual(service.clusterID, "existing")
        XCTAssertEqual(service.keychainAccount, "authority-bearer-token")
        XCTAssertEqual(service.nodeDisplayNames["server"], "Primary Mac")
        XCTAssertTrue(configuration.additionalServices.isEmpty)
    }

    func testServiceCatalogAndScopedNamesRoundTripWithoutCredentials() throws {
        var configuration = WitnessConfiguration()
        configuration.nodeDisplayNames = ["server": "SwiftBot Mac"]
        configuration.additionalServices = [GuardedService(name: "Worker", clusterID: "worker", nodeDisplayNames: ["server": "Worker Mac"])]
        XCTAssertTrue(configuration.isValid)
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(WitnessConfiguration.self, from: data)
        XCTAssertEqual(configuration, decoded)
        XCTAssertNotEqual(decoded.guardedServices[0].keychainAccount, decoded.guardedServices[1].keychainAccount)
        XCTAssertEqual(decoded.guardedServices[1].nodeDisplayNames["server"], "Worker Mac")
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: "bearer-token"))
    }

    func testDuplicateOwnershipGroupsAndMalformedServicesAreRejected() {
        var configuration = WitnessConfiguration()
        configuration.additionalServices = [GuardedService(name: "Worker", clusterID: configuration.clusterID)]
        XCTAssertFalse(configuration.isValid)
        configuration.additionalServices = [GuardedService(id: "swiftbot", name: "Worker", clusterID: "worker")]
        XCTAssertFalse(configuration.isValid)
        configuration.additionalServices = [GuardedService(name: "Worker\nName", clusterID: "worker")]
        XCTAssertFalse(configuration.isValid)
        configuration.additionalServices = [GuardedService(name: "Worker", clusterID: "worker\t")]
        XCTAssertFalse(configuration.isValid)
    }

    func testManagedTunnelRequiresMatchingLoopbackEndpointAndCompleteMetadata() {
        var configuration = WitnessConfiguration()
        configuration.tunnel.hostname = "witness.example.com"
        XCTAssertFalse(configuration.isValid)
        configuration.tunnel.tunnelID = UUID().uuidString.lowercased()
        configuration.tunnel.accountID = "account"
        configuration.publicEndpoint = configuration.tunnel.publicURL
        XCTAssertTrue(configuration.isValid)
        configuration.bindAddress = "0.0.0.0"
        XCTAssertFalse(configuration.isValid)
        configuration.bindAddress = "127.0.0.1"
        configuration.publicEndpoint = "https://bot.example.com"
        XCTAssertFalse(configuration.isValid)
    }
}
