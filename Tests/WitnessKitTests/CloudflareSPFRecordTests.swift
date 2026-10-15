import XCTest
@testable import WitnessKit

final class CloudflareSPFRecordTests: XCTestCase {
    func testAddsSenderBeforeAllWithoutReplacingExistingMechanisms() throws {
        let result = try CloudflareSPFRecord.addingInclude("include:mail.example.net", to: "v=spf1 include:_spf.google.com ip4:192.0.2.4 ~all")
        XCTAssertEqual(result, "v=spf1 include:_spf.google.com ip4:192.0.2.4 include:mail.example.net ~all")
    }

    func testPreservesRedirectAndDoesNotDuplicateExistingInclude() throws {
        XCTAssertEqual(try CloudflareSPFRecord.addingInclude("include:mail.example.net", to: "v=spf1 redirect=_spf.example.net"),
                       "v=spf1 include:mail.example.net redirect=_spf.example.net")
        XCTAssertEqual(try CloudflareSPFRecord.addingInclude("include:mail.example.net", to: "v=spf1 include:mail.example.net -all"),
                       "v=spf1 include:mail.example.net -all")
    }

    func testRejectsMalformedOrOversizedEdits() {
        XCTAssertThrowsError(try CloudflareSPFRecord.addingInclude("include:mail.example.net", to: "not spf"))
        XCTAssertThrowsError(try CloudflareSPFRecord.addingInclude("ip4:192.0.2.1", to: "v=spf1 -all"))
        let long = "v=spf1 " + String(repeating: "a", count: 245) + " -all"
        XCTAssertThrowsError(try CloudflareSPFRecord.addingInclude("include:mail.example.net", to: long))
    }
}
