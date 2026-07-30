import XCTest
@testable import VPNDNSCore

final class QbtTunnelStatusTests: XCTestCase {
    func testParseQbtDevice() {
        let json = #"{"name":"Cool Otter","pubkey":"abc=","ipv4_address":"10.151.12.34"}"#
        XCTAssertEqual(parseQbtDevice(json), QbtDevice(address: "10.151.12.34"))
        XCTAssertNil(parseQbtDevice("{}"))
        XCTAssertNil(parseQbtDevice(""))
    }

    func testParseIfconfigHasAddress() {
        let up = """
        utun100: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1160
        \tinet 10.151.12.34 --> 10.64.0.1 netmask 0xffffffff
        """
        XCTAssertTrue(parseIfconfigHasAddress(up, address: "10.151.12.34"))
        XCTAssertFalse(parseIfconfigHasAddress(up, address: "10.151.12.3"))   // prefix must not match
        XCTAssertFalse(parseIfconfigHasAddress("ifconfig: interface utun100 does not exist", address: "10.151.12.34"))
    }

    func testParseQbtListening() {
        let lsof = """
        COMMAND     PID          USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        qbittorre 39025 nicholassmith   25u  IPv4  0xdead      0t0  TCP 10.151.12.34:13794 (LISTEN)
        """
        XCTAssertTrue(parseQbtListening(lsof, address: "10.151.12.34"))
        XCTAssertFalse(parseQbtListening(lsof, address: "10.9.9.9"))
        XCTAssertFalse(parseQbtListening("", address: "10.151.12.34"))
    }

    func testParseExitHostname() {
        let json = #"{"ip":"1.2.3.4","mullvad_exit_ip_hostname":"ca-mtr-wg-306","organization":"X"}"#
        XCTAssertEqual(parseExitHostname(json), "ca-mtr-wg-306")
        XCTAssertNil(parseExitHostname(#"{"ip":"1.2.3.4"}"#))
    }

    func testDeriveQbtState() {
        XCTAssertEqual(deriveQbtState(installed: false, ifaceUp: false, alive: false, qbtRunning: false, qbtListening: false, relay: nil), .notInstalled)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: false, alive: false, qbtRunning: true, qbtListening: false, relay: nil), .tunnelDown)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: false, qbtRunning: true, qbtListening: true, relay: nil), .tunnelDown)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: true, qbtRunning: false, qbtListening: false, relay: "x"), .qbtNotRunning)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: true, qbtRunning: true, qbtListening: false, relay: "x"), .qbtNotBound)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: true, qbtRunning: true, qbtListening: true, relay: "ca-mtr-wg-306"), .active(relay: "ca-mtr-wg-306"))
    }

    func testQbtRowLabels() {
        XCTAssertEqual(qbtRowLabel(.active(relay: "ca-mtr-wg-306")), "qBittorrent: ● via ca-mtr-wg-306")
        XCTAssertEqual(qbtRowLabel(.active(relay: nil)), "qBittorrent: ● tunneled")
        XCTAssertEqual(qbtRowLabel(.qbtNotRunning), "qBittorrent: ● tunnel up · qbt not running")
        XCTAssertEqual(qbtRowLabel(.qbtNotBound), "qBittorrent: ◐ tunnel up · qbt not bound")
        XCTAssertEqual(qbtRowLabel(.tunnelDown), "qBittorrent: ○ tunnel down — torrents stalled (safe)")
        XCTAssertEqual(qbtRowLabel(.notInstalled), "qBittorrent: not installed")
    }
}
