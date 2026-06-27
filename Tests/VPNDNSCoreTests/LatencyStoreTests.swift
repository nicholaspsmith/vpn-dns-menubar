import XCTest
@testable import VPNDNSCore

private func pool() -> CandidatePool {
    CandidatePool(
        generated: "t",
        us: [
            CandidateRelay(city: "DC", cc: "us", cityCode: "was", ip: "1", seedMs: 25),
            CandidateRelay(city: "NJ", cc: "us", cityCode: "uyk", ip: "2", seedMs: 28),
            CandidateRelay(city: "Boston", cc: "us", cityCode: "bos", ip: "3", seedMs: 35),
            CandidateRelay(city: "Seattle", cc: "us", cityCode: "sea", ip: "4", seedMs: 73),
        ],
        nonus: [
            CandidateRelay(city: "Montreal", cc: "ca", cityCode: "mtr", ip: "5", seedMs: 37),
        ]
    )
}

final class LatencyStoreTests: XCTestCase {
    func testTopCitiesUsesSeedsByDefault() {
        let s = LatencyStore(pool: pool())
        let top = s.topCities(region: .us, n: 3).map { $0.cityCode }
        XCTAssertEqual(top, ["was", "uyk", "bos"])
    }
    func testMeasurementOverridesSeedAndReranks() {
        let s = LatencyStore(pool: pool())
        let t = Date(timeIntervalSince1970: 1000)
        // Make Seattle the fastest and DC the slowest.
        s.recordAll([
            CityLatency(cityCode: "sea", ms: 10, measuredAt: t, direct: true),
            CityLatency(cityCode: "was", ms: 200, measuredAt: t, direct: true),
        ])
        let top = s.topCities(region: .us, n: 3).map { $0.cityCode }
        XCTAssertEqual(top, ["sea", "uyk", "bos"])
        XCTAssertEqual(s.ms(for: pool().us[0]), 200) // DC now 200
    }
    func testUnreachableSinksToBottom() {
        let s = LatencyStore(pool: pool())
        let t = Date(timeIntervalSince1970: 1000)
        s.recordAll([CityLatency(cityCode: "was", ms: 9999, measuredAt: t, direct: true)])
        XCTAssertEqual(s.topCities(region: .us, n: 1).map { $0.cityCode }, ["uyk"])
    }
    func testLastDirectMeasurement() {
        let s = LatencyStore(pool: pool())
        XCTAssertNil(s.lastDirectMeasurement)
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        s.recordAll([
            CityLatency(cityCode: "was", ms: 25, measuredAt: t1, direct: true),
            CityLatency(cityCode: "uyk", ms: 28, measuredAt: t2, direct: true),
        ])
        XCTAssertEqual(s.lastDirectMeasurement, t2)
    }
    func testPersistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let t = Date(timeIntervalSince1970: 1234)
        let s1 = LatencyStore(pool: pool(), fileURL: url)
        s1.recordAll([CityLatency(cityCode: "was", ms: 12, measuredAt: t, direct: true)])

        let s2 = LatencyStore(pool: pool(), fileURL: url) // re-read from disk
        XCTAssertEqual(s2.ms(for: pool().us[0]), 12)
        XCTAssertEqual(s2.lastDirectMeasurement, t)
    }
}
