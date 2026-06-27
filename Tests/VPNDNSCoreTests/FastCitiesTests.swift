import XCTest
@testable import VPNDNSCore

final class FastCitiesTests: XCTestCase {
    func testCurrentCityCodeParsing() {
        XCTAssertEqual(currentCityCode(fromRelay: "us-was-wg-002"), "was")
        XCTAssertEqual(currentCityCode(fromRelay: "ca-mtr-wg-001"), "mtr")
        XCTAssertNil(currentCityCode(fromRelay: nil))
        XCTAssertNil(currentCityCode(fromRelay: "garbage"))
        XCTAssertNil(currentCityCode(fromRelay: ""))
    }
    func testIsCurrentCity() {
        XCTAssertTrue(isCurrentCity(relay: "us-was-wg-002", cc: "us", cityCode: "was"))
        XCTAssertFalse(isCurrentCity(relay: "us-was-wg-002", cc: "us", cityCode: "bos"))
        XCTAssertFalse(isCurrentCity(relay: "ca-mtr-wg-001", cc: "us", cityCode: "mtr")) // cc differs
        XCTAssertFalse(isCurrentCity(relay: nil, cc: "us", cityCode: "was"))
    }
    func testToggleConnectsWhenNotOnCity() {
        XCTAssertEqual(toggleAction(currentRelay: "ca-mtr-wg-001", clickedCC: "us", clickedCityCode: "was"),
                       .connect(cc: "us", cityCode: "was"))
        XCTAssertEqual(toggleAction(currentRelay: nil, clickedCC: "us", clickedCityCode: "bos"),
                       .connect(cc: "us", cityCode: "bos"))
    }
    func testToggleDisconnectsWhenAlreadyOnCity() {
        XCTAssertEqual(toggleAction(currentRelay: "us-was-wg-002", clickedCC: "us", clickedCityCode: "was"),
                       .disconnect)
    }
}
