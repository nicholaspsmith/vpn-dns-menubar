import XCTest
@testable import VPNDNSCore

final class SplitTunnelTests: XCTestCase {
    func testParseSplitTunnel() {
        let raw = """
        Split tunneling state: on
        Excluded applications:
        /Applications/Arc.app/Contents/MacOS/Arc
        /Users/nicholassmith/.local/share/claude/versions/2.1.220
        """
        let st = parseSplitTunnel(raw)
        XCTAssertTrue(st.enabled)
        XCTAssertEqual(st.apps, [
            "/Applications/Arc.app/Contents/MacOS/Arc",
            "/Users/nicholassmith/.local/share/claude/versions/2.1.220",
        ])

        let off = parseSplitTunnel("Split tunneling state: off\nExcluded applications:\n")
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off.apps, [])

        let empty = parseSplitTunnel("")
        XCTAssertFalse(empty.enabled)
        XCTAssertEqual(empty.apps, [])
    }

    func testSplitTunnelAppDisplayName() {
        XCTAssertEqual(splitTunnelAppDisplayName("/Applications/Arc.app/Contents/MacOS/Arc"), "Arc")
        XCTAssertEqual(splitTunnelAppDisplayName("/Applications/Plex Media Server.app/Contents/MacOS/Plex Media Server"), "Plex Media Server")
        XCTAssertEqual(splitTunnelAppDisplayName("/Applications/iTerm.app/Contents/MacOS/iTerm2"), "iTerm")
        XCTAssertEqual(splitTunnelAppDisplayName("/Users/nicholassmith/.local/share/claude/versions/2.1.220"), "claude (2.1.220)")
        XCTAssertEqual(splitTunnelAppDisplayName("/usr/local/bin/foo"), "foo")
    }

    func testSplitTunnelLabels() {
        XCTAssertEqual(splitTunnelMenuTitle(true), "Split Tunnel: On")
        XCTAssertEqual(splitTunnelMenuTitle(false), "Split Tunnel: Off")
        XCTAssertEqual(splitTunnelToggleLabel(true), "Disable Split Tunneling")
        XCTAssertEqual(splitTunnelToggleLabel(false), "Enable Split Tunneling")
    }
}
