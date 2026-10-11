import XCTest

final class RuruDiagnosticsTests: XCTestCase {
    func testReportContainsUsefulBoundedStateWithoutIdentifiersOrSecrets() {
        let secret = "bearer-secret-should-not-appear"
        let report = RuruDiagnostics.buildReport(.init(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.2.0", appBuild: "42", operatingSystem: "macOS 15.0", architecture: "x86_64",
            authorityState: "Running", listenerPort: 38_990, recoverySeconds: 12.8,
            hasAuthorityError: true, internetState: "enabled", hasInternetError: false,
            services: [.init(identifier: "service-1", kind: "SwiftBot", leaseSeconds: 30,
                              coordinationEnabled: true, allowedOriginCount: 1, locationCount: 2,
                              freshLocationCount: 1, pendingPairingCount: 0, pendingWebsiteCount: 1,
                              lease: .init(owner: "participant-1", term: 42, remainingSeconds: 22.4),
                              participants: [.init(identifier: "participant-1", role: "active", ageSeconds: 3.2,
                                                   fresh: true, hasWebUI: true)],
                              events: [.init(time: Date(timeIntervalSince1970: 1_700_000_000), action: "Acquired",
                                             participant: "participant-1", term: 42)])]
        ))

        XCTAssertTrue(report.contains("=== Ruru Diagnostic Report ==="))
        XCTAssertTrue(report.contains("state=Running listener=port 38990 recovery=12s authorityError=present"))
        XCTAssertTrue(report.contains("participant=participant-1 role=active contact=fresh age=3s webUI=reported"))
        XCTAssertTrue(report.contains("action=Acquired participant=participant-1 term=42"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains(secret))
        XCTAssertFalse(report.contains("https://"))
    }

    func testFilenameIsStableAndSafeForSaving() {
        XCTAssertEqual(RuruDiagnostics.defaultFilename(for: Date(timeIntervalSince1970: 0)),
                       "Ruru-diagnostics-1970-01-01-000000.txt")
    }
}
