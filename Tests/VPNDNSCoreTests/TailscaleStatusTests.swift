import XCTest
@testable import VPNDNSCore

final class TailscaleStatusTests: XCTestCase {
    func testBackendState() {
        XCTAssertEqual(parseTailscaleBackend("{\n  \"BackendState\": \"Stopped\",\n}"), "Stopped")
        XCTAssertEqual(parseTailscaleBackend("  \"BackendState\": \"Running\","), "Running")
        XCTAssertEqual(parseTailscaleBackend("{}"), "Unknown")
    }
    func testCorpDNS() {
        XCTAssertTrue(parseCorpDNS("\t\"CorpDNS\": true,"))
        XCTAssertFalse(parseCorpDNS("\t\"CorpDNS\": false,"))
        XCTAssertFalse(parseCorpDNS("{}"))
    }
}
