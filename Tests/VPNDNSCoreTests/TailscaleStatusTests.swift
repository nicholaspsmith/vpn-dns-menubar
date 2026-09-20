// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import VPNDNSCore

final class TailscaleStatusTests: XCTestCase {
    func testBackendState() {
        XCTAssertEqual(parseTailscaleBackend("{\n  \"BackendState\": \"Stopped\",\n}"), "Stopped")
        XCTAssertEqual(parseTailscaleBackend("  \"BackendState\": \"Running\","), "Running")
        XCTAssertEqual(parseTailscaleBackend("{}"), "Unknown")
    }
    func testCorpDNS() {
        XCTAssertTrue(parseCorpDNS("\t\"CorpDNS\": true,"))
        XCTAssertFalse(parseCorpDNS("\t\"CorpDNS\": false,"))
        XCTAssertFalse(parseCorpDNS("{}"))
    }
}
