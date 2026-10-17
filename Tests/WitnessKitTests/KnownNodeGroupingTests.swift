import XCTest
@testable import WitnessKit

final class KnownNodeGroupingTests: XCTestCase {
    private let names = ["a": "DevMini", "b": "DevMini", "c": "DevMini", "d": "JohnBook"]

    func testHistoryOnlyIDsWithLiveSameNameBecomeEarlier() {
        let result = KnownNodeGrouping.group(nodes: ["a", "b", "c", "d"], names: names, live: ["c"], pinned: [])
        XCTAssertEqual(result.current, ["c", "d"])
        XCTAssertEqual(result.earlier, ["a", "b"])
    }

    func testPreferredPrimaryStaysCurrent() {
        let result = KnownNodeGrouping.group(nodes: ["a", "b", "c"], names: names, live: ["c"], pinned: ["a"])
        XCTAssertEqual(result.current, ["a", "c"])
        XCTAssertEqual(result.earlier, ["b"])
    }

    func testNothingIsHiddenWithoutALiveSameNameServer() {
        let result = KnownNodeGrouping.group(nodes: ["a", "b"], names: names, live: [], pinned: [])
        XCTAssertEqual(result.current, ["a", "b"])
        XCTAssertTrue(result.earlier.isEmpty)
    }

    func testUnnamedNodesAreNeverMerged() {
        let result = KnownNodeGrouping.group(nodes: ["x", "y"], names: [:], live: ["y"], pinned: [])
        XCTAssertEqual(result.current, ["x", "y"])
    }
}
