import XCTest
@testable import VPNDNSCore

final class MullvadStatusTests: XCTestCase {
    func testDisconnected() {
        let raw = """
        Disconnected
            Visible location:       United States, Charleston. IPv4: 67.39.147.85
        """
        let s = parseMullvadStatus(raw)
        XCTAssertEqual(s.state, .off)
        XCTAssertNil(s.relay)
        XCTAssertEqual(s.location, "United States, Charleston. IPv4: 67.39.147.85")
    }

    func testConnected() {
        let raw = """
        Connected
            Relay:                  us-bos-wg-001
            Visible location:       United States, Boston. IPv4: 1.2.3.4
        """
        let s = parseMullvadStatus(raw)
        XCTAssertEqual(s.state, .connected)
        XCTAssertEqual(s.relay, "us-bos-wg-001")
        XCTAssertEqual(s.location, "United States, Boston. IPv4: 1.2.3.4")
    }

    func testBlockedAndConnecting() {
        XCTAssertEqual(parseMullvadStatus("Blocked\n").state, .blocked)
        XCTAssertEqual(parseMullvadStatus("Connecting to ...\n").state, .connecting)
        XCTAssertEqual(parseMullvadStatus("Disconnecting...\n").state, .disconnecting)
    }
}
