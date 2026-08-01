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

    // qBittorrent reaches the network only through the SOCKS5 proxy, so
    // "wired up correctly" means it holds a connection to 127.0.0.1:1080.
    func testParseProxyListening() {
        let lsof = """
        COMMAND   PID          USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Python  23487 nicholassmith    6u  IPv4  0xbeef      0t0  TCP 127.0.0.1:1080 (LISTEN)
        """
        XCTAssertTrue(parseProxyListening(lsof))
        XCTAssertFalse(parseProxyListening(""))
    }

    func testParseQbtUsingProxy() {
        let lsof = """
        COMMAND     PID          USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        qbittorre 93565 nicholassmith   39u  IPv4  0xdead      0t0  TCP 127.0.0.1:50442->127.0.0.1:1080 (ESTABLISHED)
        """
        XCTAssertTrue(parseQbtUsingProxy(lsof))
        XCTAssertFalse(parseQbtUsingProxy("qbittorre 1 u IPv4 TCP 192.168.1.170:5->1.2.3.4:443 (ESTABLISHED)"))
        XCTAssertFalse(parseQbtUsingProxy(""))
    }

    func testParseExitHostname() {
        let json = #"{"ip":"1.2.3.4","mullvad_exit_ip_hostname":"ca-mtr-wg-306","organization":"X"}"#
        XCTAssertEqual(parseExitHostname(json), "ca-mtr-wg-306")
        XCTAssertNil(parseExitHostname(#"{"ip":"1.2.3.4"}"#))
    }

    func testDeriveQbtState() {
        func s(_ installed: Bool, _ ifaceUp: Bool, _ alive: Bool, _ proxyUp: Bool,
               _ running: Bool, _ viaProxy: Bool, _ relay: String?) -> QbtTunnelState {
            deriveQbtState(installed: installed, ifaceUp: ifaceUp, alive: alive,
                           proxyUp: proxyUp, qbtRunning: running,
                           qbtUsingProxy: viaProxy, relay: relay)
        }
        XCTAssertEqual(s(false, false, false, false, false, false, nil), .notInstalled)
        XCTAssertEqual(s(true, false, false, true, true, true, nil), .tunnelDown)
        XCTAssertEqual(s(true, true, false, true, true, true, nil), .tunnelDown)
        // tunnel healthy but the proxy is down: qbt has no path out (fail closed)
        XCTAssertEqual(s(true, true, true, false, true, false, "x"), .proxyDown)
        XCTAssertEqual(s(true, true, true, true, false, false, "x"), .qbtNotRunning)
        XCTAssertEqual(s(true, true, true, true, true, false, "x"), .qbtNotBound)
        XCTAssertEqual(s(true, true, true, true, true, true, "ca-mtr-wg-306"), .active(relay: "ca-mtr-wg-306"))
    }

    func testQbtRowLabels() {
        XCTAssertEqual(qbtRowLabel(.active(relay: "ca-mtr-wg-306")), "qBittorrent: ● via ca-mtr-wg-306")
        XCTAssertEqual(qbtRowLabel(.active(relay: nil)), "qBittorrent: ● tunneled")
        XCTAssertEqual(qbtRowLabel(.qbtNotRunning), "qBittorrent: ● tunnel up · qbt not running")
        XCTAssertEqual(qbtRowLabel(.qbtNotBound), "qBittorrent: ◐ qbt not using proxy")
        XCTAssertEqual(qbtRowLabel(.proxyDown), "qBittorrent: ○ proxy down — torrents stalled (safe)")
        XCTAssertEqual(qbtRowLabel(.tunnelDown), "qBittorrent: ○ tunnel down — torrents stalled (safe)")
        XCTAssertEqual(qbtRowLabel(.notInstalled), "qBittorrent: not installed")
    }
}
