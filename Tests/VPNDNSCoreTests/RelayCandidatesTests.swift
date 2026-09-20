// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import VPNDNSCore

final class RelayCandidatesTests: XCTestCase {
    func testLoadDecodesPool() throws {
        let json = """
        {
          "generated": "2026-06-26",
          "us": [
            {"city":"Washington DC","cc":"us","cityCode":"was","ip":"185.213.193.127","seedMs":25}
          ],
          "nonus": [
            {"city":"Montreal","cc":"ca","cityCode":"mtr","ip":"146.70.198.66","seedMs":37}
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cand-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pool = try loadCandidates(from: url)
        XCTAssertEqual(pool.generated, "2026-06-26")
        XCTAssertEqual(pool.us.count, 1)
        XCTAssertEqual(pool.nonus.first?.cityCode, "mtr")
        XCTAssertEqual(pool.us.first?.seedMs, 25)
    }

    func testLoadThrowsOnMalformed() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).json")
        try? "{ not json".data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try loadCandidates(from: url))
    }
}
