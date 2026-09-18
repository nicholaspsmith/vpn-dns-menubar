import XCTest
@testable import VPNDNSCore

final class VPNPresentationTests: XCTestCase {
    func testDotColor() {
        XCTAssertEqual(dotColor(for: .connected), .green)
        XCTAssertEqual(dotColor(for: .connecting), .orange)
        XCTAssertEqual(dotColor(for: .blocked), .red)
        XCTAssertEqual(dotColor(for: .off), .grey)
    }
    // The three status rows share one shape: a dot, a name, whatever detail
    // that row has, and the state as the last word. They sit under
    // "Mullvad"/"Tailscale" group headers, so the name is the thing itself
    // rather than the product.
    func testStatusRowLabelShape() {
        XCTAssertEqual(statusRowLabel(name: "Connection", detail: "us-bos-wg-001", state: "ON"),
                       "Connection — us-bos-wg-001 · ON")
        // No detail: the row is just the name and the state, never a dangling dash.
        XCTAssertEqual(statusRowLabel(name: "MagicDNS", detail: nil, state: "OFF"), "MagicDNS · OFF")
        XCTAssertEqual(statusRowLabel(name: "Connection", detail: "", state: "ON"), "Connection · ON")
    }

    func testMullvadRowLabel() {
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .connected, relay: "us-bos-wg-001", location: "X")),
            "Connection — us-bos-wg-001 · ON"
        )
        // Off with a remembered location: the location is still worth showing,
        // but the state is what the row ends on.
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: "United States")),
            "Connection — United States · OFF"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: nil)),
            "Connection · OFF"
        )
        // In-between states say what they are rather than pretending to be binary.
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .connecting, relay: nil, location: "Sweden")),
            "Connection — Sweden · CONNECTING"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .blocked, relay: nil, location: nil)),
            "Connection · BLOCKED"
        )
    }

    func testTailscaleRowLabel() {
        XCTAssertEqual(tailscaleRowLabel("Running"), "Connection · ON")
        XCTAssertEqual(tailscaleRowLabel("Stopped"), "Connection · OFF")
        // A backend state that is neither is the detail, so the row explains
        // why it is off rather than just saying so.
        XCTAssertEqual(tailscaleRowLabel("NeedsLogin"), "Connection — needs login · OFF")
        XCTAssertEqual(tailscaleRowLabel("Starting"), "Connection — starting · OFF")
    }

    func testAcceptDNSLabel() {
        XCTAssertEqual(acceptDNSLabel(true), "MagicDNS — accept-dns · ON")
        XCTAssertEqual(acceptDNSLabel(false), "MagicDNS — accept-dns · OFF")
    }

    func testOtherLabels() {
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
}
