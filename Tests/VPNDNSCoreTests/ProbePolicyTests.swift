// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import VPNDNSCore

final class ProbePolicyTests: XCTestCase {
    func testDecisionTruthTable() {
        // Off: plain direct probe (split tunneling irrelevant).
        XCTAssertEqual(probeDecision(mullvadOff: true, splitTunnelOn: false), .probeDirect)
        XCTAssertEqual(probeDecision(mullvadOff: true, splitTunnelOn: true), .probeDirect)
        // Connected: only via split tunnel, and only if it's already on.
        XCTAssertEqual(probeDecision(mullvadOff: false, splitTunnelOn: true), .probeViaSplitTunnel)
        XCTAssertEqual(probeDecision(mullvadOff: false, splitTunnelOn: false), .skip)
    }
    func testProbePingPath() {
        XCTAssertEqual(probePingPath, "/sbin/ping")
    }
}
