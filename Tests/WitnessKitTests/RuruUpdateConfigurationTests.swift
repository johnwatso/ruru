import XCTest

final class RuruUpdateConfigurationTests: XCTestCase {
    private let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    func testStableAndBetaUseRuruFeeds() throws {
        let config = try XCTUnwrap(RuruUpdateConfiguration(info: [
            "SUFeedURL": "https://johnwatso.github.io/ruru/appcast.xml",
            "SUPublicEDKey": publicKey
        ]))
        XCTAssertEqual(config.feedURL(for: .stable).absoluteString, "https://johnwatso.github.io/ruru/appcast.xml")
        XCTAssertEqual(config.feedURL(for: .beta).absoluteString, "https://johnwatso.github.io/ruru/beta/appcast.xml")
    }

    func testMissingShipHookKeyDisablesConfiguration() {
        for key in ["", "$(SPARKLE_PUBLIC_ED_KEY)", "not-a-key", Data(repeating: 7, count: 31).base64EncodedString()] {
            XCTAssertNil(RuruUpdateConfiguration(info: [
                "SUFeedURL": "https://johnwatso.github.io/ruru/appcast.xml", "SUPublicEDKey": key
            ]))
        }
    }

    func testRejectsInsecureOrUnresolvedFeeds() {
        for feed in ["", "$(SPARKLE_FEED_URL)", "http://example.com/appcast.xml",
                     "https://user:secret@example.com/appcast.xml", "https://example.com/appcast.xml?token=secret",
                     "https://example.com/appcast.xml#fragment", "https://example.com/"] {
            XCTAssertNil(RuruUpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": publicKey]))
        }
    }
}
