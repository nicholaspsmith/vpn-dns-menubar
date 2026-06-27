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
    func testSectionsHeadersAndTopThreeTitles() {
        let s = LatencyStore(pool: menuPool())
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.us.header, "Fastest US (No-ID)")
        XCTAssertEqual(m.nonus.header, "Fastest Non-US (No-ID · torrent-safe)")
        XCTAssertEqual(m.us.rows.map { $0.title },
                       ["Washington DC — 25 ms", "Secaucus, NJ — 28 ms", "Boston, MA — 35 ms"])
        XCTAssertEqual(m.nonus.rows.map { $0.title },
                       ["Montreal — 37 ms", "Toronto — 43 ms", "Queretaro — 51 ms"])
    }
    func testCurrentCityMarked() {
        let s = LatencyStore(pool: menuPool())
        let m = fastCitiesMenu(store: s, currentRelay: "us-was-wg-002", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(m.us.rows[0].isCurrent)   // DC
        XCTAssertFalse(m.us.rows[1].isCurrent)
        XCTAssertEqual(m.us.rows[0].cc, "us")
        XCTAssertEqual(m.us.rows[0].cityCode, "was")
    }
    func testFreshnessSeedVsMeasured() {
        XCTAssertEqual(freshnessText(nil, now: Date(timeIntervalSince1970: 5000)),
                       "measured: seed values")
        let t = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1000 + 2*3600) // 2h later
        XCTAssertEqual(freshnessText(t, now: now), "measured 2h ago (direct)")
    }
}
