import XCTest
@testable import VPNDNSCore

final class LatencyTests: XCTestCase {
    func testParseMinFromMacPingSummary() {
        let out = """
        12 packets transmitted, 12 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 35.977/53.316/162.151/32.482 ms
        """
        XCTAssertEqual(parsePingMinRTT(out)!, 35.977, accuracy: 0.0001)
    }
    func testParseWithPacketLossStillReadsMin() {
        let out = """
        20 packets transmitted, 19 packets received, 5.0% packet loss
        round-trip min/avg/max/stddev = 39.913/56.693/162.233/31.525 ms
        """
        XCTAssertEqual(parsePingMinRTT(out)!, 39.913, accuracy: 0.0001)
    }
    func testParseNoRoundTripLineReturnsNil() {
        let out = "20 packets transmitted, 0 packets received, 100.0% packet loss"
        XCTAssertNil(parsePingMinRTT(out))
    }
    func testParseEmptyAndJunkReturnNil() {
        XCTAssertNil(parsePingMinRTT(""))
        XCTAssertNil(parsePingMinRTT("totally unrelated text"))
    }
}
