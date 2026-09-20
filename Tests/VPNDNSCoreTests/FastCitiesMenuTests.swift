// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import VPNDNSCore

private func menuPool() -> CandidatePool {
    CandidatePool(
        generated: "t",
        us: [
            CandidateRelay(city: "Washington DC", cc: "us", cityCode: "was", ip: "1", seedMs: 25),
            CandidateRelay(city: "Secaucus, NJ", cc: "us", cityCode: "uyk", ip: "2", seedMs: 28),
            CandidateRelay(city: "Boston, MA", cc: "us", cityCode: "bos", ip: "3", seedMs: 35),
            CandidateRelay(city: "Seattle, WA", cc: "us", cityCode: "sea", ip: "4", seedMs: 73),
        ],
        nonus: [
            CandidateRelay(city: "Montreal", cc: "ca", cityCode: "mtr", ip: "5", seedMs: 37),
            CandidateRelay(city: "Toronto", cc: "ca", cityCode: "tor", ip: "6", seedMs: 43),
            CandidateRelay(city: "Queretaro", cc: "mx", cityCode: "qro", ip: "7", seedMs: 51),
        ]
    )
}

final class FastCitiesMenuTests: XCTestCase {
    func testSectionsHeadersAndTopFiveTitles() {
        let s = LatencyStore(pool: menuPool())
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.sections[0].header, "Fastest US (No-ID)")
        XCTAssertEqual(m.sections[1].header, "Fastest Non-US (No-ID · torrent-safe)")
        XCTAssertEqual(m.sections[0].rows.map { $0.title },
                       ["Washington DC — 25 ms", "Secaucus, NJ — 28 ms", "Boston, MA — 35 ms",
                        "Seattle, WA — 73 ms"])
        XCTAssertEqual(m.sections[1].rows.map { $0.title },
                       ["Montreal — 37 ms", "Toronto — 43 ms", "Queretaro — 51 ms"])
    }

    func testTopFiveCapsAtFive() {
        let pool = CandidatePool(
            generated: "t",
            us: [
                CandidateRelay(city: "A", cc: "us", cityCode: "aaa", ip: "1", seedMs: 10),
                CandidateRelay(city: "B", cc: "us", cityCode: "bbb", ip: "2", seedMs: 20),
                CandidateRelay(city: "C", cc: "us", cityCode: "ccc", ip: "3", seedMs: 30),
                CandidateRelay(city: "D", cc: "us", cityCode: "ddd", ip: "4", seedMs: 40),
                CandidateRelay(city: "E", cc: "us", cityCode: "eee", ip: "5", seedMs: 50),
                CandidateRelay(city: "F", cc: "us", cityCode: "fff", ip: "6", seedMs: 60),
            ],
            nonus: []
        )
        let s = LatencyStore(pool: pool)
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.sections[0].rows.map { $0.cityCode }, ["aaa", "bbb", "ccc", "ddd", "eee"])
        XCTAssertEqual(m.sections.map { $0.list }, [.us])
    }
    func testCurrentCityMarked() {
        let s = LatencyStore(pool: menuPool())
        let m = fastCitiesMenu(store: s, currentRelay: "us-was-wg-002", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(m.sections[0].rows[0].isCurrent)   // DC
        XCTAssertFalse(m.sections[0].rows[1].isCurrent)
        XCTAssertEqual(m.sections[0].rows[0].cc, "us")
        XCTAssertEqual(m.sections[0].rows[0].cityCode, "was")
    }
    func testFreshnessSeedVsMeasured() {
        XCTAssertEqual(freshnessText(nil, now: Date(timeIntervalSince1970: 5000)),
                       "measured: seed values")
        let t = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1000 + 2*3600) // 2h later
        XCTAssertEqual(freshnessText(t, now: now), "measured 2h ago (direct)")
    }
}
