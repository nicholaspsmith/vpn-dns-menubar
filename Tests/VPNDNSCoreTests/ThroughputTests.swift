// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import VPNDNSCore

private func tpPool() -> CandidatePool {
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
        ]
    )
}

final class CurlSpeedParseTests: XCTestCase {
    func testBytesPerSecondBecomesMbps() {
        // curl -w '%{http_code} %{speed_download}' prints bytes/s; 51 895 617 B/s ≈ 415.2 Mbit/s
        XCTAssertEqual(parseCurlSpeedMbps("200 51895617\n")!, 415.16, accuracy: 0.01)
    }
    func testNon200ZeroAndGarbageAreNil() {
        XCTAssertNil(parseCurlSpeedMbps("403 4\n"))      // over Cloudflare's size cap
        XCTAssertNil(parseCurlSpeedMbps("000 0\n"))      // connection failed
        XCTAssertNil(parseCurlSpeedMbps("200 0\n"))
        XCTAssertNil(parseCurlSpeedMbps(""))
        XCTAssertNil(parseCurlSpeedMbps("curl: (28) timed out"))
    }
    func testSecondTransferIsSizedToTargetSeconds() {
        // 30 MB/s probe → 150 MB for 5 s, clamped to the 90 MB cap.
        XCTAssertEqual(transferBytes(afterProbeMbps: 240, targetSeconds: 5, minBytes: 10_000_000, maxBytes: 90_000_000),
                       90_000_000)
        // 8 Mbit/s → 1 MB/s → 5 MB, clamped up to the floor.
        XCTAssertEqual(transferBytes(afterProbeMbps: 8, targetSeconds: 5, minBytes: 10_000_000, maxBytes: 90_000_000),
                       10_000_000)
        // 80 Mbit/s → 10 MB/s → 50 MB.
        XCTAssertEqual(transferBytes(afterProbeMbps: 80, targetSeconds: 5, minBytes: 10_000_000, maxBytes: 90_000_000),
                       50_000_000)
    }
}

final class ThroughputStoreTests: XCTestCase {
    func testThroughputModeRanksByDownloadDescending() {
        let s = LatencyStore(pool: tpPool())
        let t = Date(timeIntervalSince1970: 1000)
        s.recordThroughput([
            CityThroughput(cityCode: "sea", downMbps: 400, upMbps: 50, measuredAt: t),
            CityThroughput(cityCode: "was", downMbps: 120, upMbps: 90, measuredAt: t),
            CityThroughput(cityCode: "uyk", downMbps: 900, upMbps: 10, measuredAt: t),
            CityThroughput(cityCode: "bos", downMbps: 300, upMbps: 10, measuredAt: t),
        ])
        XCTAssertEqual(s.topCities(list: .us, n: 3, mode: .throughput).map { $0.cityCode },
                       ["uyk", "sea", "bos"])
        // Latency mode is untouched by throughput data.
        XCTAssertEqual(s.topCities(list: .us, n: 3, mode: .latency).map { $0.cityCode },
                       ["was", "uyk", "bos"])
    }
    func testUntestedCitiesSinkBelowTestedInLatencyOrder() {
        let s = LatencyStore(pool: tpPool())
        let t = Date(timeIntervalSince1970: 1000)
        s.recordThroughput([CityThroughput(cityCode: "sea", downMbps: 400, upMbps: 50, measuredAt: t)])
        XCTAssertEqual(s.topCities(list: .us, n: 5, mode: .throughput).map { $0.cityCode },
                       ["sea", "was", "uyk", "bos"])
    }
    func testLastThroughputMeasurementAndLookup() {
        let s = LatencyStore(pool: tpPool())
        XCTAssertNil(s.lastThroughputMeasurement)
        XCTAssertNil(s.throughput(for: tpPool().us[0]))
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        s.recordThroughput([
            CityThroughput(cityCode: "was", downMbps: 1, upMbps: 1, measuredAt: t1),
            CityThroughput(cityCode: "uyk", downMbps: 2, upMbps: 2, measuredAt: t2),
        ])
        XCTAssertEqual(s.lastThroughputMeasurement, t2)
        XCTAssertEqual(s.throughput(for: tpPool().us[0])?.downMbps, 1)
    }
    func testThroughputPersistsSeparatelyFromLatency() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lat = dir.appendingPathComponent("latency.json")
        let tp = dir.appendingPathComponent("throughput.json")
        let t = Date(timeIntervalSince1970: 1234)
        let s1 = LatencyStore(pool: tpPool(), fileURL: lat, throughputURL: tp)
        s1.recordThroughput([CityThroughput(cityCode: "was", downMbps: 77, upMbps: 8, measuredAt: t)])

        let s2 = LatencyStore(pool: tpPool(), fileURL: lat, throughputURL: tp)
        XCTAssertEqual(s2.throughput(for: tpPool().us[0])?.downMbps, 77)
        XCTAssertEqual(s2.lastThroughputMeasurement, t)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lat.path)) // latency file untouched
    }
}

final class ThroughputMenuTests: XCTestCase {
    func testThroughputModeTitlesAndFooters() {
        let s = LatencyStore(pool: tpPool())
        let t = Date(timeIntervalSince1970: 1000)
        s.recordThroughput([
            CityThroughput(cityCode: "sea", downMbps: 412.4, upMbps: 88.2, measuredAt: t),
        ])
        let now = Date(timeIntervalSince1970: 1000 + 3 * 86400)
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: now, mode: .throughput)
        XCTAssertEqual(m.sections[0].rows.map { $0.title },
                       ["Seattle, WA — ↓ 412 ↑ 88 Mbps",
                        "Washington DC — 25 ms · not tested",
                        "Secaucus, NJ — 28 ms · not tested",
                        "Boston, MA — 35 ms · not tested"])
        XCTAssertEqual(m.footer, "measured: seed values")
        XCTAssertEqual(m.throughputFooter, "throughput measured 3d ago")
    }
    func testLatencyModeIsDefaultAndUnchanged() {
        let s = LatencyStore(pool: tpPool())
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.sections[0].rows[0].title, "Washington DC — 25 ms")
        XCTAssertEqual(m.throughputFooter, "throughput: not measured")
    }
    func testRankModeRoundTripsThroughRawValue() {
        XCTAssertEqual(RankMode(rawValue: "throughput"), .throughput)
        XCTAssertEqual(RankMode(rawValue: "latency"), .latency)
        XCTAssertEqual(RankMode.allCases, [.latency, .throughput])
        XCTAssertEqual(RankMode.latency.menuTitle, "Rank by Latency")
        XCTAssertEqual(RankMode.throughput.menuTitle, "Rank by Throughput")
    }
    func testProgressTitle() {
        XCTAssertEqual(throughputProgressTitle(done: 3, total: 21, city: "Chicago, IL"),
                       "Measuring throughput… 4/21 Chicago, IL")
    }
}

final class RelayLocationParseTests: XCTestCase {
    private func out(_ loc: String) -> String {
        """
        Generic constraints
            Location:               \(loc)
            Provider(s):            any
            Ownership:              any
        WireGuard constraints
            IP protocol:            any
        """
    }
    func testCity() {
        XCTAssertEqual(parseRelayLocation(out("city qro, mx")), .city(cc: "mx", city: "qro"))
        XCTAssertEqual(RelayLocation.city(cc: "mx", city: "qro").restoreArgs,
                       ["relay", "set", "location", "mx", "qro"])
    }
    func testCountryAndAny() {
        XCTAssertEqual(parseRelayLocation(out("country se")), .country(cc: "se"))
        XCTAssertEqual(RelayLocation.country(cc: "se").restoreArgs, ["relay", "set", "location", "se"])
        XCTAssertEqual(parseRelayLocation(out("any")), .any)
        XCTAssertEqual(RelayLocation.any.restoreArgs, ["relay", "set", "location", "any"])
    }
    func testHostname() {
        XCTAssertEqual(parseRelayLocation(out("city got, se, hostname se-got-wg-004")),
                       .hostname(cc: "se", city: "got", host: "se-got-wg-004"))
        XCTAssertEqual(RelayLocation.hostname(cc: "se", city: "got", host: "se-got-wg-004").restoreArgs,
                       ["relay", "set", "location", "se", "got", "se-got-wg-004"])
    }
    func testCustomListIsBareName() {
        XCTAssertEqual(parseRelayLocation(out("No-ID L1 under 1000mi")), .customList(name: "No-ID L1 under 1000mi"))
        XCTAssertEqual(RelayLocation.customList(name: "No-ID L1 under 1000mi").restoreArgs,
                       ["relay", "set", "custom-list", "No-ID L1 under 1000mi"])
    }
    func testMissingLineIsNil() {
        XCTAssertNil(parseRelayLocation(""))
        XCTAssertNil(parseRelayLocation("garbage\n"))
    }
}

final class ThroughputRestoreTests: XCTestCase {
    func testRestoresLocationThenReconnectsWhenItWasConnected() {
        XCTAssertEqual(throughputRestoreCommands(location: .city(cc: "mx", city: "qro"), wasConnected: true),
                       [["relay", "set", "location", "mx", "qro"], ["connect", "--wait"]])
    }
    func testRestoresLocationThenDisconnectsWhenItWasOff() {
        XCTAssertEqual(throughputRestoreCommands(location: .customList(name: "L1"), wasConnected: false),
                       [["relay", "set", "custom-list", "L1"], ["disconnect"]])
    }
    func testUnknownLocationStillRestoresConnectionState() {
        XCTAssertEqual(throughputRestoreCommands(location: nil, wasConnected: false), [["disconnect"]])
        XCTAssertEqual(throughputRestoreCommands(location: nil, wasConnected: true), [["connect", "--wait"]])
    }
}
