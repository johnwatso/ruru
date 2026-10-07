import Foundation
import XCTest
import WitnessKit

final class WitnessConfigurationTests: XCTestCase {
    private let bot = GuardedService(name: "SwiftBot", clusterID: "swiftmesh", kind: .swiftBot)

    private func configured(_ services: GuardedService...) -> WitnessConfiguration {
        var configuration = WitnessConfiguration()
        configuration.services = services
        return configuration
    }

    func testFreshConfigurationHasNoBuiltInService() throws {
        let configuration = WitnessConfiguration()
        XCTAssertTrue(configuration.guardedServices.isEmpty)
        XCTAssertTrue(configuration.isValid)
        let restored = try JSONDecoder().decode(WitnessConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored, configuration)
    }

    func testEveryServiceIsEqualAndTheSwiftBotTemplateOnlyChangesPresentation() {
        let worker = GuardedService(name: "Worker", clusterID: "worker")
        XCTAssertEqual(bot.brandAsset, "SwiftBotLogo")
        XCTAssertNil(worker.brandAsset)
        XCTAssertEqual(bot.keychainAccount, "service-" + bot.id)
        XCTAssertEqual(worker.keychainAccount, "service-" + worker.id)
        XCTAssertEqual(bot.leaseSeconds, worker.leaseSeconds)
        XCTAssertTrue(configured(bot, worker).isValid)
    }

    func testLeaseLengthIsBoundedAndPersists() throws {
        var service = GuardedService(name: "Media", clusterID: "media", leaseSeconds: 120)
        XCTAssertTrue(configured(service).isValid)
        let restored = try JSONDecoder().decode(WitnessConfiguration.self, from: JSONEncoder().encode(configured(service)))
        XCTAssertEqual(restored.services.first?.leaseSeconds, 120)
        for invalid in [0, 9, 301] {
            service.leaseSeconds = invalid
            XCTAssertFalse(configured(service).isValid)
        }
        let withoutLength = Data(#"{"id":"\#(bot.id)","name":"SwiftBot","clusterID":"swiftmesh"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(GuardedService.self, from: withoutLength).leaseSeconds, 30)
    }

    func testCoordinationPolicyPersistsAndRemovedServiceDoesNotTransferOptIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruCoordinationPolicy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var configuration = configured(bot)
        XCTAssertFalse(configuration.coordinationPolicy(for: bot.id).enabled)
        let policy = CoordinationPolicy(enabled: true, allowedOrigins: ["https://media.example.com"])
        try configuration.setCoordinationPolicy(policy, for: bot.id)
        try WitnessStorage.save(configuration, in: folder)
        let restored = try WitnessStorage.load(from: folder)
        XCTAssertEqual(restored.coordinationPolicy(for: bot.id), policy)
        XCTAssertThrowsError(try configuration.setCoordinationPolicy(policy, for: "missing"))
        XCTAssertThrowsError(try configuration.setCoordinationPolicy(.init(enabled: true, allowedOrigins: ["https://media.example.com/path"]), for: bot.id))
        try configuration.removeGuardedService(id: bot.id)
        XCTAssertTrue(configuration.serviceCoordinationPolicies.isEmpty)
        let replacement = GuardedService(name: "Replacement", clusterID: bot.clusterID)
        configuration.services = [replacement]
        XCTAssertFalse(configuration.coordinationPolicy(for: replacement.id).enabled)
        configuration.serviceCoordinationPolicies["missing"] = policy
        XCTAssertFalse(configuration.isValid)
    }

    func testPrimaryPreferencePersistsPerServiceAndClearingAdvancesRevision() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruPrimaryPreference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let worker = GuardedService(name: "Worker", clusterID: "worker")
        var configuration = configured(bot, worker)
        XCTAssertTrue(try configuration.setPreferredPrimary("primary-a", for: bot.id))
        XCTAssertTrue(try configuration.setPreferredPrimary("worker-b", for: worker.id))
        XCTAssertFalse(try configuration.setPreferredPrimary("primary-a", for: bot.id))
        try WitnessStorage.save(configuration, in: folder)
        var restored = try WitnessStorage.load(from: folder)
        XCTAssertEqual(restored.primaryPreference(for: bot.id).preferredPrimaryNodeID, "primary-a")
        XCTAssertEqual(restored.primaryPreference(for: worker.id).preferredPrimaryNodeID, "worker-b")
        XCTAssertEqual(restored.primaryPreference(for: bot.id).revision, 1)
        XCTAssertTrue(try restored.setPreferredPrimary(nil, for: bot.id))
        try WitnessStorage.save(restored, in: folder)
        let cleared = try WitnessStorage.load(from: folder)
        XCTAssertNil(cleared.primaryPreference(for: bot.id).preferredPrimaryNodeID)
        XCTAssertEqual(cleared.primaryPreference(for: bot.id).revision, 2)
        XCTAssertEqual(cleared.primaryPreference(for: worker.id).revision, 1)
        XCTAssertEqual(cleared.services, configuration.services)
        XCTAssertEqual(cleared.tunnel, configuration.tunnel)
    }

    func testPreferenceRejectsInvalidIDsAndRemovedServicesCannotInheritPreferences() throws {
        var configuration = configured(bot)
        for invalid in ["", "  node", "node\n", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try configuration.setPreferredPrimary(invalid, for: bot.id))
        }
        XCTAssertThrowsError(try configuration.setPreferredPrimary("node", for: "missing"))
        try configuration.setPreferredPrimary("node-a", for: bot.id)
        try configuration.removeGuardedService(id: bot.id)
        XCTAssertTrue(configuration.servicePrimaryPreferences.isEmpty)
        XCTAssertTrue(configuration.serviceCoordinationPolicies.isEmpty)
        let replacement = GuardedService(name: "Replacement", clusterID: bot.clusterID)
        configuration.services = [replacement]
        XCTAssertNil(configuration.primaryPreference(for: replacement.id).preferredPrimaryNodeID)
        XCTAssertEqual(configuration.primaryPreference(for: replacement.id).revision, 0)
        configuration.servicePrimaryPreferences["missing"] = .init(preferredPrimaryNodeID: "node")
        XCTAssertFalse(configuration.isValid)
    }

    func testPreferenceRevisionExhaustionFailsWithoutChangingSelection() throws {
        var configuration = configured(bot)
        configuration.servicePrimaryPreferences[bot.id] = .init(preferredPrimaryNodeID: "node-a", revision: Int64.max)
        XCTAssertThrowsError(try configuration.setPreferredPrimary("node-b", for: bot.id))
        XCTAssertEqual(configuration.primaryPreference(for: bot.id).preferredPrimaryNodeID, "node-a")
        configuration.servicePrimaryPreferences[bot.id] = .init(revision: -1)
        XCTAssertFalse(configuration.isValid)
    }

    func testPreReleaseSettingsWithoutAServiceListAreRejectedNotEmptied() {
        let data = Data(#"{"clusterID":"my-cluster","bindAddress":"127.0.0.1","port":38990,"publicEndpoint":"","startAutomatically":false}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WitnessConfiguration.self, from: data))
    }

    func testRetiredKeysAreIgnoredAndDropped() throws {
        let data = Data(#"{"bindAddress":"127.0.0.1","port":38990,"publicEndpoint":"","startAutomatically":true,"showInDock":true,"appearance":"dark","services":[]}"#.utf8)
        let configuration = try JSONDecoder().decode(WitnessConfiguration.self, from: data)
        XCTAssertTrue(configuration.showInDock)
        XCTAssertTrue(configuration.isValid)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        XCTAssertNil(encoded?["appearance"])
        XCTAssertEqual(encoded?["showInDock"] as? Bool, true)
    }

    func testMissingRequiredSettingsAreNotSilentlyReplaced() {
        XCTAssertThrowsError(try JSONDecoder().decode(WitnessConfiguration.self, from: Data("{}".utf8)))
    }

    func testRemovingServicesSurvivesRestartAndAllowsAnEmptyCatalog() throws {
        let worker = GuardedService(name: "Worker", clusterID: "worker")
        var configuration = configured(bot, worker)
        configuration.showInDock = true
        try configuration.removeGuardedService(id: bot.id)
        XCTAssertEqual(configuration.guardedServices, [worker])
        XCTAssertTrue(configuration.isValid)
        let restored = try JSONDecoder().decode(WitnessConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.guardedServices, [worker])
        XCTAssertTrue(restored.showInDock)
        try configuration.removeGuardedService(id: worker.id)
        XCTAssertTrue(configuration.guardedServices.isEmpty)
        XCTAssertTrue(configuration.isValid)
        XCTAssertThrowsError(try configuration.removeGuardedService(id: "missing"))
    }

    func testNewServiceCanReuseARemovedGroupWithADistinctCredential() throws {
        var configuration = configured(bot)
        try configuration.removeGuardedService(id: bot.id)
        let replacement = GuardedService(name: "Replacement", clusterID: bot.clusterID, kind: .swiftBot)
        configuration.services = [replacement]
        XCTAssertTrue(configuration.isValid)
        XCTAssertNotEqual(replacement.keychainAccount, bot.keychainAccount)
    }

    func testServiceCatalogAndScopedNamesRoundTripWithoutCredentials() throws {
        var named = bot
        named.nodeDisplayNames = ["server": "SwiftBot Mac"]
        let configuration = configured(named, GuardedService(name: "Worker", clusterID: "worker", nodeDisplayNames: ["server": "Worker Mac"]))
        XCTAssertTrue(configuration.isValid)
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(WitnessConfiguration.self, from: data)
        XCTAssertEqual(configuration, decoded)
        XCTAssertNotEqual(decoded.guardedServices[0].keychainAccount, decoded.guardedServices[1].keychainAccount)
        XCTAssertEqual(decoded.guardedServices[0].nodeDisplayNames["server"], "SwiftBot Mac")
        XCTAssertEqual(decoded.guardedServices[1].nodeDisplayNames["server"], "Worker Mac")
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: "token"))
    }

    func testDuplicateOwnershipGroupsAndMalformedServicesAreRejected() {
        XCTAssertFalse(configured(bot, GuardedService(name: "Worker", clusterID: bot.clusterID)).isValid)
        XCTAssertFalse(configured(bot, GuardedService(id: bot.id, name: "Worker", clusterID: "worker")).isValid)
        XCTAssertFalse(configured(GuardedService(id: "swiftbot", name: "Worker", clusterID: "worker")).isValid)
        XCTAssertFalse(configured(GuardedService(name: "Worker\nName", clusterID: "worker")).isValid)
        XCTAssertFalse(configured(GuardedService(name: "Worker", clusterID: "worker\t")).isValid)
    }

    func testManagedTunnelRequiresMatchingLoopbackEndpointAndCompleteMetadata() {
        var configuration = WitnessConfiguration()
        configuration.tunnel.hostname = "ruru.example.com"
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

    func testApprovedWebsitePersistsWithoutChangingOwnershipOrOtherServices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruEnrollment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = GuardedService(name: "Other", clusterID: "other")
        var configuration = configured(bot, other)
        try configuration.setPreferredPrimary("owner", for: bot.id)
        try configuration.setCoordinationPolicy(.init(enabled: true, allowedOrigins: ["https://other.example.com"]), for: other.id)
        let before = configuration
        try configuration.approveCoordinationOrigin("https://john.example.com", for: bot.id)
        try configuration.approveCoordinationOrigin("https://max.example.com", for: bot.id)
        try configuration.approveCoordinationOrigin("https://max.example.com", for: bot.id)
        try WitnessStorage.save(configuration, in: folder)
        let restored = try WitnessStorage.load(from: folder)
        XCTAssertEqual(restored.coordinationPolicy(for: bot.id), .init(enabled: true,
            allowedOrigins: ["https://john.example.com", "https://max.example.com"]))
        XCTAssertEqual(restored.coordinationPolicy(for: other.id), before.coordinationPolicy(for: other.id))
        XCTAssertEqual(restored.servicePrimaryPreferences, before.servicePrimaryPreferences)
        XCTAssertEqual(restored.services, before.services)
        XCTAssertEqual(restored.tunnel, before.tunnel)
        for index in 2..<8 { try configuration.approveCoordinationOrigin("https://node-\(index).example.com", for: bot.id) }
        let full = configuration
        XCTAssertThrowsError(try configuration.approveCoordinationOrigin("https://overflow.example.com", for: bot.id))
        XCTAssertThrowsError(try configuration.approveCoordinationOrigin("http://node.example.com", for: bot.id))
        XCTAssertThrowsError(try configuration.approveCoordinationOrigin("https://node.example.com", for: "missing"))
        XCTAssertEqual(configuration, full)
    }
}
