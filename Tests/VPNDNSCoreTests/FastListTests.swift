import XCTest
@testable import VPNDNSCore

private func regionalPool() -> CandidatePool {
    CandidatePool(
        generated: "t",
        us: [
            CandidateRelay(city: "Washington DC", cc: "us", cityCode: "was", ip: "1", seedMs: 25),
        ],
        nonus: [
            CandidateRelay(city: "Montreal", cc: "ca", cityCode: "mtr", ip: "2", seedMs: 35),
            CandidateRelay(city: "Toronto", cc: "ca", cityCode: "tor", ip: "3", seedMs: 44),
            CandidateRelay(city: "Queretaro", cc: "mx", cityCode: "qro", ip: "4", seedMs: 70),
            CandidateRelay(city: "Bogota", cc: "co", cityCode: "bog", ip: "5", seedMs: 89),
            CandidateRelay(city: "Lima", cc: "pe", cityCode: "lim", ip: "6", seedMs: 109),
            CandidateRelay(city: "Tirana", cc: "al", cityCode: "tia", ip: "7", seedMs: 126),
            CandidateRelay(city: "Belgrade", cc: "rs", cityCode: "beg", ip: "8", seedMs: 130),
            CandidateRelay(city: "Santiago", cc: "cl", cityCode: "scl", ip: "9", seedMs: 133),
            CandidateRelay(city: "Kyiv", cc: "ua", cityCode: "iev", ip: "10", seedMs: 148),
            CandidateRelay(city: "Tel Aviv", cc: "il", cityCode: "tlv", ip: "11", seedMs: 159),
            CandidateRelay(city: "Buenos Aires", cc: "ar", cityCode: "bue", ip: "12", seedMs: 168),
            CandidateRelay(city: "Manila", cc: "ph", cityCode: "mnl", ip: "13", seedMs: 246),
            CandidateRelay(city: "Bangkok", cc: "th", cityCode: "bkk", ip: "14", seedMs: 278),
        ]
    )
}

final class FastListTests: XCTestCase {
    func testListOrderAndHeaders() {
        XCTAssertEqual(FastList.allCases, [.us, .nonus, .canada, .latinAmerica, .europe, .asia])
        XCTAssertEqual(FastList.us.header, "Fastest US (No-ID)")
        XCTAssertEqual(FastList.nonus.header, "Fastest Non-US (No-ID · torrent-safe)")
        XCTAssertEqual(FastList.canada.header, "Fastest Canada (No-ID)")
        XCTAssertEqual(FastList.latinAmerica.header, "Fastest Latin America (No-ID)")
        XCTAssertEqual(FastList.europe.header, "Fastest Europe (No-ID)")
        XCTAssertEqual(FastList.asia.header, "Fastest Asia (No-ID)")
    }

    func testRegionalListsSliceTheNonUSPoolByCountry() {
        let s = LatencyStore(pool: regionalPool())
        XCTAssertEqual(s.topCities(list: .canada, n: 5).map { $0.cityCode }, ["mtr", "tor"])
        XCTAssertEqual(s.topCities(list: .latinAmerica, n: 5).map { $0.cityCode },
                       ["qro", "bog", "lim", "scl", "bue"])
        XCTAssertEqual(s.topCities(list: .europe, n: 5).map { $0.cityCode }, ["tia", "beg", "iev"])
        XCTAssertEqual(s.topCities(list: .asia, n: 5).map { $0.cityCode }, ["mnl", "bkk"])
    }

    func testIsraelStaysInNonUSButHasNoRegionalList() {
        let s = LatencyStore(pool: regionalPool())
        XCTAssertTrue(s.topCities(list: .nonus, n: 20).map { $0.cityCode }.contains("tlv"))
        for list in FastList.allCases where list != .nonus {
            XCTAssertFalse(s.topCities(list: list, n: 20).map { $0.cityCode }.contains("tlv"), "\(list)")
        }
    }

    func testUSAndNonUSListsUnchanged() {
        let s = LatencyStore(pool: regionalPool())
        XCTAssertEqual(s.topCities(list: .us, n: 5).map { $0.cityCode }, ["was"])
        XCTAssertEqual(s.topCities(list: .nonus, n: 3).map { $0.cityCode }, ["mtr", "tor", "qro"])
    }

    func testRegionalListRanksByMeasuredLatency() {
        let s = LatencyStore(pool: regionalPool())
        let t = Date(timeIntervalSince1970: 1000)
        s.recordAll([CityLatency(cityCode: "bue", ms: 20, measuredAt: t, direct: true)])
        XCTAssertEqual(s.topCities(list: .latinAmerica, n: 2).map { $0.cityCode }, ["bue", "qro"])
    }

    func testMenuEmitsOneSectionPerListInOrderDroppingEmpty() {
        let s = LatencyStore(pool: regionalPool())
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.sections.map { $0.list }, FastList.allCases)
        XCTAssertEqual(m.sections.map { $0.header }, FastList.allCases.map { $0.header })
        XCTAssertEqual(m.sections[2].rows.map { $0.title }, ["Montreal — 35 ms", "Toronto — 44 ms"])

        let usOnly = CandidatePool(generated: "t", us: regionalPool().us, nonus: [])
        let m2 = fastCitiesMenu(store: LatencyStore(pool: usOnly), currentRelay: nil,
                                now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m2.sections.map { $0.list }, [.us])
    }

    func testVisibleSectionsFiltersHiddenLists() {
        let s = LatencyStore(pool: regionalPool())
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(visibleSections(m.sections, hidden: []).map { $0.list }, FastList.allCases)
        XCTAssertEqual(visibleSections(m.sections, hidden: [.nonus, .europe]).map { $0.list },
                       [.us, .canada, .latinAmerica, .asia])
    }
}
