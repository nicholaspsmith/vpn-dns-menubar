import XCTest
@testable import VPNDNSCore

final class ProbePolicyTests: XCTestCase {
    func testStaleWhenNeverMeasured() {
        XCTAssertTrue(isLatencyStale(last: nil, now: Date(timeIntervalSince1970: 0), maxAge: 43200))
    }
    func testFreshAtExactlyMaxAge() {
        let last = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(isLatencyStale(last: last, now: Date(timeIntervalSince1970: 43200), maxAge: 43200))
    }
    func testStaleBeyondMaxAge() {
        let last = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(isLatencyStale(last: last, now: Date(timeIntervalSince1970: 43201), maxAge: 43200))
    }
    func testDecisionTruthTable() {
        // Fresh data: never probe, regardless of state.
        XCTAssertEqual(probeDecision(stale: false, mullvadOff: true, splitTunnelOn: true), .skip)
        XCTAssertEqual(probeDecision(stale: false, mullvadOff: false, splitTunnelOn: false), .skip)
        // Stale + off: plain direct probe (split tunneling irrelevant).
        XCTAssertEqual(probeDecision(stale: true, mullvadOff: true, splitTunnelOn: false), .probeDirect)
        XCTAssertEqual(probeDecision(stale: true, mullvadOff: true, splitTunnelOn: true), .probeDirect)
        // Stale + connected: only via split tunnel, and only if it's already on.
        XCTAssertEqual(probeDecision(stale: true, mullvadOff: false, splitTunnelOn: true), .probeViaSplitTunnel)
        XCTAssertEqual(probeDecision(stale: true, mullvadOff: false, splitTunnelOn: false), .skip)
    }
    func testProbePingPath() {
        XCTAssertEqual(probePingPath, "/sbin/ping")
    }
}
