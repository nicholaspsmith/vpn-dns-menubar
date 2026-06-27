import XCTest
@testable import VPNDNSCore

final class VPNPresentationTests: XCTestCase {
    func testDotColor() {
        XCTAssertEqual(dotColor(for: .connected), .green)
        XCTAssertEqual(dotColor(for: .connecting), .orange)
        XCTAssertEqual(dotColor(for: .blocked), .red)
        XCTAssertEqual(dotColor(for: .off), .grey)
    }
    func testMullvadRowLabel() {
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .connected, relay: "us-bos-wg-001", location: "X")),
            "Mullvad: Connected — us-bos-wg-001"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: "United States")),
            "Mullvad: Off — United States"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: nil)),
            "Mullvad: Off"
        )
    }
    func testOtherLabels() {
        XCTAssertEqual(acceptDNSLabel(true), "accept-dns (MagicDNS): ON")
        XCTAssertEqual(acceptDNSLabel(false), "accept-dns (MagicDNS): OFF")
        XCTAssertEqual(tailscaleRowLabel("Running"), "Tailscale: Running")
        XCTAssertEqual(tailscaleColor("Running"), .green)
        XCTAssertEqual(tailscaleColor("Stopped"), .grey)
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
