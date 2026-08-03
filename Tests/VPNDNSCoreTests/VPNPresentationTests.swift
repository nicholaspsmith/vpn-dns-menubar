import XCTest
@testable import VPNDNSCore

final class VPNPresentationTests: XCTestCase {
    func testDotColor() {
        XCTAssertEqual(dotColor(for: .connected), .green)
        XCTAssertEqual(dotColor(for: .connecting), .orange)
        XCTAssertEqual(dotColor(for: .blocked), .red)
        XCTAssertEqual(dotColor(for: .off), .grey)
    }
    // Rows sit under "Mullvad"/"Tailscale" group headers, so labels carry no prefix.
    func testMullvadRowLabel() {
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .connected, relay: "us-bos-wg-001", location: "X")),
            "Connected — us-bos-wg-001"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: "United States")),
            "Off — United States"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: nil)),
            "Off"
        )
    }
    func testOtherLabels() {
        XCTAssertEqual(acceptDNSLabel(true), "accept-dns (MagicDNS): ON")
        XCTAssertEqual(acceptDNSLabel(false), "accept-dns (MagicDNS): OFF")
        XCTAssertEqual(tailscaleRowLabel("Running"), "Status: Running")
        XCTAssertEqual(tailscaleColor("Running"), .green)
        XCTAssertEqual(tailscaleColor("Stopped"), .grey)
    }

    func testAcceptDNSDotColor() {
        XCTAssertEqual(acceptDNSDotColor(true), .green)
        XCTAssertEqual(acceptDNSDotColor(false), .grey)
    }

    // Off connects (to Mullvad's own persisted relay selection); any live or
    // in-flight state disconnects.
    func testMullvadToggle() {
        XCTAssertEqual(mullvadToggle(.off), .connect)
        XCTAssertEqual(mullvadToggle(.connected), .disconnect)
        XCTAssertEqual(mullvadToggle(.connecting), .disconnect)
        XCTAssertEqual(mullvadToggle(.disconnecting), .disconnect)
        XCTAssertEqual(mullvadToggle(.blocked), .disconnect)
    }

    // The menu-bar dot combines both states: blue when Tailscale is the active
    // path (Mullvad off + Tailscale running); Mullvad states otherwise win.
    func testDotBlueWhenTailscaleRunningAndMullvadOff() {
        XCTAssertEqual(dotColor(mullvad: .off, tailscaleRunning: true), .blue)
    }
    func testMullvadStateWinsOverTailscaleRunning() {
        XCTAssertEqual(dotColor(mullvad: .connected, tailscaleRunning: true), .green)
        XCTAssertEqual(dotColor(mullvad: .connecting, tailscaleRunning: true), .orange)
        XCTAssertEqual(dotColor(mullvad: .blocked, tailscaleRunning: true), .red)
    }
    func testGreyWhenMullvadOffAndTailscaleNotRunning() {
        XCTAssertEqual(dotColor(mullvad: .off, tailscaleRunning: false), .grey)
    }
    func testTailscaleToggleDecision() {
        XCTAssertEqual(tailscaleToggle("Running"), .down)
        XCTAssertEqual(tailscaleToggle("Stopped"), .up)
        XCTAssertEqual(tailscaleToggle("NeedsLogin"), .up)
        XCTAssertEqual(tailscaleToggle("Unknown"), .up)
    }
    func testTailscaleToggleLabel() {
        XCTAssertEqual(tailscaleToggleLabel("Running"), "Disconnect Tailscale")
        XCTAssertEqual(tailscaleToggleLabel("Stopped"), "Connect Tailscale")
    }
}
