# Fastest No-ID Cities Menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two menu-bar sections — "Fastest US (No-ID)" and "Fastest Non-US (No-ID · torrent-safe)" — each listing the top 3 fastest qualifying Mullvad cities as click-to-toggle (connect/disconnect) items, ranked by latency the app measures itself.

**Architecture:** Pure, testable logic in `VPNDNSCore` (ping parsing, candidate model + JSON loader, latency store + ranking, toggle decisions, menu model). AppKit wiring in `Sources/VPNDNSMenuBar/main.swift` renders the sections and runs a latency probe that only measures when Mullvad is disconnected (so numbers are direct, not tunneled). Candidate cities + seed latencies live in `Resources/bundle/candidates.json`, copied into the `.app` by the existing `make-app.sh`.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest, StatusItemKit (sibling package), `mullvad` + `/sbin/ping` via `StatusItemKit.Shell.run`.

## Global Constraints

- **Core stays pure:** `VPNDNSCore` imports only `Foundation` (no AppKit). AppKit lives only in `Sources/VPNDNSMenuBar/main.swift`.
- **Latency is only ever recorded while Mullvad is `off`** — measuring through the tunnel is wrong. The probe re-checks the off-state before committing.
- **Candidate data location:** `Resources/bundle/candidates.json` (copied into the app by `../StatusItemKit/scripts/make-app.sh`). Do **not** add it as a SwiftPM `resources:` entry — `make-app.sh` does not copy SwiftPM resource bundles. (This supersedes the spec's "Package.swift bundle resource" line; no `Package.swift` change is needed.)
- **Section titles (verbatim):** `Fastest US (No-ID)` and `Fastest Non-US (No-ID · torrent-safe)`.
- **City row title format (verbatim):** `<City> — <ms> ms` (em dash `—`, integer ms).
- **Torrent filter:** New Zealand is excluded from the non-US pool (active Copyright Tribunal regime); all other No-ID countries stay.
- **Branch:** do all work on `feature/fastest-noid-cities` (repo is currently on `main`).
- **Commits:** the user's standing rule is "commit only when asked." Treat each task's commit step as a checkpoint — stage the changes and ask before committing (or batch on request). Do not push.
- **Run tests with:** `swift test` from the repo root (`~/Code/vpn-dns-menubar`).

---

## Setup (do once, before Task 1)

- [ ] Create and switch to the feature branch:

```bash
cd ~/Code/vpn-dns-menubar
git checkout -b feature/fastest-noid-cities
```

---

### Task 1: Ping RTT parser

**Files:**
- Create: `Sources/VPNDNSCore/Latency.swift`
- Test: `Tests/VPNDNSCoreTests/LatencyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `func parsePingMinRTT(_ output: String) -> Double?` — returns the **min** round-trip ms from `/sbin/ping` summary output, or `nil` if absent.

- [ ] **Step 1: Write the failing test**

Create `Tests/VPNDNSCoreTests/LatencyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LatencyTests`
Expected: FAIL — `cannot find 'parsePingMinRTT' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/VPNDNSCore/Latency.swift`:

```swift
import Foundation

/// Parse the **min** round-trip time (ms) from `/sbin/ping` summary output.
/// Looks for the `round-trip min/avg/max/stddev = a/b/c/d ms` line (or Linux
/// `rtt ...`) and returns `a`. Returns nil when no summary line is present.
public func parsePingMinRTT(_ output: String) -> Double? {
    for line in output.split(separator: "\n") {
        guard line.contains("round-trip") || line.contains("rtt") else { continue }
        guard let eq = line.range(of: "= ") else { continue }
        let after = line[eq.upperBound...]
        guard let firstField = after.split(separator: "/").first else { continue }
        let num = firstField.trimmingCharacters(in: .whitespaces)
        if let v = Double(num) { return v }
    }
    return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LatencyTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit (checkpoint — see Global Constraints)**

```bash
git add Sources/VPNDNSCore/Latency.swift Tests/VPNDNSCoreTests/LatencyTests.swift
git commit -m "feat: parsePingMinRTT — read min RTT from ping output"
```

---

### Task 2: Candidate pool model, loader, and data file

**Files:**
- Create: `Sources/VPNDNSCore/RelayCandidates.swift`
- Create: `Resources/bundle/candidates.json`
- Test: `Tests/VPNDNSCoreTests/RelayCandidatesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct CandidateRelay: Codable, Equatable { let city: String; let cc: String; let cityCode: String; let ip: String; let seedMs: Double }`
  - `struct CandidatePool: Codable, Equatable { let generated: String; let us: [CandidateRelay]; let nonus: [CandidateRelay] }`
  - `func loadCandidates(from url: URL) throws -> CandidatePool`

- [ ] **Step 1: Write the failing test**

Create `Tests/VPNDNSCoreTests/RelayCandidatesTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RelayCandidatesTests`
Expected: FAIL — `cannot find 'loadCandidates' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/VPNDNSCore/RelayCandidates.swift`:

```swift
import Foundation

/// One qualifying city: a representative relay IP (for probing) and a seed
/// latency (used until a live direct measurement replaces it).
public struct CandidateRelay: Codable, Equatable {
    public let city: String       // "Washington DC"
    public let cc: String         // "us"
    public let cityCode: String   // "was"
    public let ip: String         // representative relay IPv4
    public let seedMs: Double     // seed latency in ms

    public init(city: String, cc: String, cityCode: String, ip: String, seedMs: Double) {
        self.city = city
        self.cc = cc
        self.cityCode = cityCode
        self.ip = ip
        self.seedMs = seedMs
    }
}

/// The full candidate pool, split into US and non-US sections.
public struct CandidatePool: Codable, Equatable {
    public let generated: String
    public let us: [CandidateRelay]
    public let nonus: [CandidateRelay]

    public init(generated: String, us: [CandidateRelay], nonus: [CandidateRelay]) {
        self.generated = generated
        self.us = us
        self.nonus = nonus
    }
}

public func loadCandidates(from url: URL) throws -> CandidatePool {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CandidatePool.self, from: data)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RelayCandidatesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Create the real data file**

Create `Resources/bundle/candidates.json` with exactly this content (measured 2026-06-26; NZ excluded):

```json
{
  "generated": "2026-06-26",
  "us": [
    {"city":"Washington DC","cc":"us","cityCode":"was","ip":"185.213.193.127","seedMs":25},
    {"city":"Secaucus, NJ","cc":"us","cityCode":"uyk","ip":"104.36.50.33","seedMs":28},
    {"city":"Boston, MA","cc":"us","cityCode":"bos","ip":"43.225.189.131","seedMs":35},
    {"city":"Chicago, IL","cc":"us","cityCode":"chi","ip":"87.249.134.1","seedMs":36},
    {"city":"Detroit, MI","cc":"us","cityCode":"det","ip":"185.141.119.131","seedMs":39},
    {"city":"Seattle, WA","cc":"us","cityCode":"sea","ip":"138.199.43.78","seedMs":73}
  ],
  "nonus": [
    {"city":"Montreal","cc":"ca","cityCode":"mtr","ip":"146.70.198.66","seedMs":37},
    {"city":"Toronto","cc":"ca","cityCode":"tor","ip":"178.249.214.2","seedMs":43},
    {"city":"Queretaro","cc":"mx","cityCode":"qro","ip":"149.88.22.129","seedMs":51},
    {"city":"Vancouver","cc":"ca","cityCode":"van","ip":"104.193.135.100","seedMs":77},
    {"city":"Calgary","cc":"ca","cityCode":"yyc","ip":"38.240.225.68","seedMs":89},
    {"city":"Bogota","cc":"co","cityCode":"bog","ip":"154.47.16.34","seedMs":89},
    {"city":"Lima","cc":"pe","cityCode":"lim","ip":"95.173.223.159","seedMs":108},
    {"city":"Tirana","cc":"al","cityCode":"tia","ip":"103.124.165.2","seedMs":127},
    {"city":"Belgrade","cc":"rs","cityCode":"beg","ip":"146.70.193.2","seedMs":128},
    {"city":"Santiago","cc":"cl","cityCode":"scl","ip":"149.88.104.15","seedMs":132},
    {"city":"Kyiv","cc":"ua","cityCode":"iev","ip":"149.102.240.66","seedMs":141},
    {"city":"Tel Aviv","cc":"il","cityCode":"tlv","ip":"169.150.227.197","seedMs":159},
    {"city":"Buenos Aires","cc":"ar","cityCode":"bue","ip":"149.22.83.31","seedMs":164},
    {"city":"Bangkok","cc":"th","cityCode":"bkk","ip":"156.59.50.194","seedMs":252},
    {"city":"Manila","cc":"ph","cityCode":"mnl","ip":"156.59.127.194","seedMs":263}
  ]
}
```

- [ ] **Step 6: Verify the data file decodes**

Run: `python3 -c "import json; d=json.load(open('Resources/bundle/candidates.json')); print(len(d['us']),'us',len(d['nonus']),'nonus')"`
Expected: `6 us 15 nonus`

- [ ] **Step 7: Commit (checkpoint)**

```bash
git add Sources/VPNDNSCore/RelayCandidates.swift Tests/VPNDNSCoreTests/RelayCandidatesTests.swift Resources/bundle/candidates.json
git commit -m "feat: candidate pool model + loader + candidates.json"
```

---

### Task 3: City toggle decisions

**Files:**
- Create: `Sources/VPNDNSCore/FastCities.swift`
- Test: `Tests/VPNDNSCoreTests/FastCitiesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `func currentCityCode(fromRelay relay: String?) -> String?`
  - `func isCurrentCity(relay: String?, cc: String, cityCode: String) -> Bool`
  - `enum ToggleAction: Equatable { case connect(cc: String, cityCode: String); case disconnect }`
  - `func toggleAction(currentRelay: String?, clickedCC: String, clickedCityCode: String) -> ToggleAction`

- [ ] **Step 1: Write the failing test**

Create `Tests/VPNDNSCoreTests/FastCitiesTests.swift`:

```swift
import XCTest
@testable import VPNDNSCore

final class FastCitiesTests: XCTestCase {
    func testCurrentCityCodeParsing() {
        XCTAssertEqual(currentCityCode(fromRelay: "us-was-wg-002"), "was")
        XCTAssertEqual(currentCityCode(fromRelay: "ca-mtr-wg-001"), "mtr")
        XCTAssertNil(currentCityCode(fromRelay: nil))
        XCTAssertNil(currentCityCode(fromRelay: "garbage"))
        XCTAssertNil(currentCityCode(fromRelay: ""))
    }
    func testIsCurrentCity() {
        XCTAssertTrue(isCurrentCity(relay: "us-was-wg-002", cc: "us", cityCode: "was"))
        XCTAssertFalse(isCurrentCity(relay: "us-was-wg-002", cc: "us", cityCode: "bos"))
        XCTAssertFalse(isCurrentCity(relay: "ca-mtr-wg-001", cc: "us", cityCode: "mtr")) // cc differs
        XCTAssertFalse(isCurrentCity(relay: nil, cc: "us", cityCode: "was"))
    }
    func testToggleConnectsWhenNotOnCity() {
        XCTAssertEqual(toggleAction(currentRelay: "ca-mtr-wg-001", clickedCC: "us", clickedCityCode: "was"),
                       .connect(cc: "us", cityCode: "was"))
        XCTAssertEqual(toggleAction(currentRelay: nil, clickedCC: "us", clickedCityCode: "bos"),
                       .connect(cc: "us", cityCode: "bos"))
    }
    func testToggleDisconnectsWhenAlreadyOnCity() {
        XCTAssertEqual(toggleAction(currentRelay: "us-was-wg-002", clickedCC: "us", clickedCityCode: "was"),
                       .disconnect)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FastCitiesTests`
Expected: FAIL — `cannot find 'currentCityCode' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/VPNDNSCore/FastCities.swift`:

```swift
import Foundation

/// City code (2nd dash-segment) of a Mullvad relay hostname, e.g.
/// "us-was-wg-002" -> "was". Returns nil for nil/malformed input.
public func currentCityCode(fromRelay relay: String?) -> String? {
    guard let relay = relay else { return nil }
    let parts = relay.split(separator: "-")
    guard parts.count >= 2 else { return nil }
    return String(parts[1])
}

/// True when `relay` is in the given country + city, e.g.
/// isCurrentCity("us-was-wg-002", cc: "us", cityCode: "was") == true.
public func isCurrentCity(relay: String?, cc: String, cityCode: String) -> Bool {
    guard let relay = relay else { return false }
    let parts = relay.split(separator: "-")
    return parts.count >= 2 && String(parts[0]) == cc && String(parts[1]) == cityCode
}

public enum ToggleAction: Equatable {
    case connect(cc: String, cityCode: String)
    case disconnect
}

/// Clicking a city toggles: disconnect if already connected to it, else connect.
public func toggleAction(currentRelay: String?, clickedCC: String, clickedCityCode: String) -> ToggleAction {
    if isCurrentCity(relay: currentRelay, cc: clickedCC, cityCode: clickedCityCode) {
        return .disconnect
    }
    return .connect(cc: clickedCC, cityCode: clickedCityCode)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FastCitiesTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit (checkpoint)**

```bash
git add Sources/VPNDNSCore/FastCities.swift Tests/VPNDNSCoreTests/FastCitiesTests.swift
git commit -m "feat: city toggle + current-city helpers"
```

---

### Task 4: Latency store (ranking + persistence)

**Files:**
- Modify: `Sources/VPNDNSCore/Latency.swift` (append types below the parser)
- Test: `Tests/VPNDNSCoreTests/LatencyStoreTests.swift`

**Interfaces:**
- Consumes: `CandidateRelay`, `CandidatePool` (Task 2); `parsePingMinRTT` (Task 1, same file).
- Produces:
  - `enum Region: String, Codable { case us, nonus }`
  - `struct CityLatency: Codable, Equatable { let cityCode: String; let ms: Double; let measuredAt: Date; let direct: Bool }`
  - `final class LatencyStore` with:
    - `init(pool: CandidatePool, fileURL: URL? = nil)`
    - `var pool: CandidatePool` (read-only get)
    - `func ms(for relay: CandidateRelay) -> Double`
    - `func recordAll(_ measurements: [CityLatency])`
    - `var lastDirectMeasurement: Date?`
    - `func topCities(region: Region, n: Int) -> [CandidateRelay]`

- [ ] **Step 1: Write the failing test**

Create `Tests/VPNDNSCoreTests/LatencyStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LatencyStoreTests`
Expected: FAIL — `cannot find 'LatencyStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/VPNDNSCore/Latency.swift`:

```swift
public enum Region: String, Codable { case us, nonus }

/// A latency measurement for one city. `direct` is true when measured with the
/// Mullvad tunnel down (the only trustworthy condition).
public struct CityLatency: Codable, Equatable {
    public let cityCode: String
    public let ms: Double
    public let measuredAt: Date
    public let direct: Bool
    public init(cityCode: String, ms: Double, measuredAt: Date, direct: Bool) {
        self.cityCode = cityCode
        self.ms = ms
        self.measuredAt = measuredAt
        self.direct = direct
    }
}

/// Holds the candidate pool plus the latest per-city measurements, ranks cities
/// by effective latency (measured if available, else seed), and persists
/// measurements to `fileURL` (JSON) when provided.
public final class LatencyStore {
    public let pool: CandidatePool
    private var measured: [String: CityLatency]
    private let fileURL: URL?

    public init(pool: CandidatePool, fileURL: URL? = nil) {
        self.pool = pool
        self.fileURL = fileURL
        if let url = fileURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: CityLatency].self, from: data) {
            self.measured = saved
        } else {
            self.measured = [:]
        }
    }

    /// Effective latency: measured value if present, otherwise the seed.
    public func ms(for relay: CandidateRelay) -> Double {
        measured[relay.cityCode]?.ms ?? relay.seedMs
    }

    public func recordAll(_ measurements: [CityLatency]) {
        for m in measurements { measured[m.cityCode] = m }
        persist()
    }

    /// Most recent direct-measurement timestamp across all cities, if any.
    public var lastDirectMeasurement: Date? {
        measured.values.filter { $0.direct }.map { $0.measuredAt }.max()
    }

    public func topCities(region: Region, n: Int) -> [CandidateRelay] {
        let list = (region == .us) ? pool.us : pool.nonus
        let sorted = list.sorted { ms(for: $0) < ms(for: $1) }
        return Array(sorted.prefix(n))
    }

    private func persist() {
        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder().encode(measured) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LatencyStoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit (checkpoint)**

```bash
git add Sources/VPNDNSCore/Latency.swift Tests/VPNDNSCoreTests/LatencyStoreTests.swift
git commit -m "feat: LatencyStore — ranking + persistence"
```

---

### Task 5: Menu model builder

**Files:**
- Modify: `Sources/VPNDNSCore/FastCities.swift` (append)
- Test: `Tests/VPNDNSCoreTests/FastCitiesMenuTests.swift`

**Interfaces:**
- Consumes: `LatencyStore`, `Region` (Task 4); `isCurrentCity` (Task 3); `CandidateRelay` (Task 2).
- Produces:
  - `struct MenuRow: Equatable { let title: String; let cc: String; let cityCode: String; let isCurrent: Bool }`
  - `struct MenuSection: Equatable { let header: String; let rows: [MenuRow] }`
  - `struct FastCitiesMenu: Equatable { let us: MenuSection; let nonus: MenuSection; let footer: String }`
  - `func freshnessText(_ last: Date?, now: Date) -> String`
  - `func fastCitiesMenu(store: LatencyStore, currentRelay: String?, now: Date, topN: Int = 3) -> FastCitiesMenu`

- [ ] **Step 1: Write the failing test**

Create `Tests/VPNDNSCoreTests/FastCitiesMenuTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FastCitiesMenuTests`
Expected: FAIL — `cannot find 'fastCitiesMenu' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/VPNDNSCore/FastCities.swift`:

```swift
public struct MenuRow: Equatable {
    public let title: String
    public let cc: String
    public let cityCode: String
    public let isCurrent: Bool
    public init(title: String, cc: String, cityCode: String, isCurrent: Bool) {
        self.title = title
        self.cc = cc
        self.cityCode = cityCode
        self.isCurrent = isCurrent
    }
}

public struct MenuSection: Equatable {
    public let header: String
    public let rows: [MenuRow]
    public init(header: String, rows: [MenuRow]) {
        self.header = header
        self.rows = rows
    }
}

public struct FastCitiesMenu: Equatable {
    public let us: MenuSection
    public let nonus: MenuSection
    public let footer: String
    public init(us: MenuSection, nonus: MenuSection, footer: String) {
        self.us = us
        self.nonus = nonus
        self.footer = footer
    }
}

/// Human freshness line for the footer.
public func freshnessText(_ last: Date?, now: Date) -> String {
    guard let last = last else { return "measured: seed values" }
    let secs = Int(now.timeIntervalSince(last))
    let ago: String
    if secs < 90 { ago = "just now" }
    else if secs < 3600 { ago = "\(secs / 60)m ago" }
    else if secs < 86400 { ago = "\(secs / 3600)h ago" }
    else { ago = "\(secs / 86400)d ago" }
    return "measured \(ago) (direct)"
}

/// Build the two menu sections (top-N cities each) plus the freshness footer.
public func fastCitiesMenu(store: LatencyStore, currentRelay: String?, now: Date,
                           topN: Int = 3) -> FastCitiesMenu {
    func section(_ region: Region, _ header: String) -> MenuSection {
        let rows = store.topCities(region: region, n: topN).map { relay -> MenuRow in
            let ms = Int(store.ms(for: relay).rounded())
            return MenuRow(
                title: "\(relay.city) — \(ms) ms",
                cc: relay.cc,
                cityCode: relay.cityCode,
                isCurrent: isCurrentCity(relay: currentRelay, cc: relay.cc, cityCode: relay.cityCode)
            )
        }
        return MenuSection(header: header, rows: rows)
    }
    return FastCitiesMenu(
        us: section(.us, "Fastest US (No-ID)"),
        nonus: section(.nonus, "Fastest Non-US (No-ID · torrent-safe)"),
        footer: freshnessText(store.lastDirectMeasurement, now: now)
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FastCitiesMenuTests`
Expected: PASS (3 tests). Then run the whole suite: `swift test` → all green.

- [ ] **Step 5: Commit (checkpoint)**

```bash
git add Sources/VPNDNSCore/FastCities.swift Tests/VPNDNSCoreTests/FastCitiesMenuTests.swift
git commit -m "feat: fastCitiesMenu model + freshness text"
```

---

### Task 6: Candidate-refresh script

**Files:**
- Create: `scripts/refresh-candidates.sh` (executable)

**Interfaces:**
- Consumes: `mullvad` CLI, `/sbin/ping`, `python3`. Writes `Resources/bundle/candidates.json` in the schema from Task 2.
- Produces: a maintainer command to re-measure and regenerate the data file.

- [ ] **Step 1: Create the script**

Create `scripts/refresh-candidates.sh`:

```bash
#!/bin/bash
# Regenerate Resources/bundle/candidates.json — the No-ID candidate cities, each
# with a representative relay IP and a freshly measured direct (tunnel-down) seed
# latency, sorted fastest-first.
#
# City set mirrors the user's Mullvad "No-ID" custom lists (jurisdictions with no
# adult-content age-verification law), split US vs non-US, minus New Zealand
# (active Copyright Tribunal torrent regime). Edit the two CITIES lists below when
# the No-ID lists change.
set -euo pipefail
cd "$(dirname "$0")/.."
MULLVAD=/usr/local/bin/mullvad
OUT=Resources/bundle/candidates.json

US_CITIES="was uyk bos chi det sea"
NONUS_CITIES="ca:mtr ca:tor ca:van ca:yyc mx:qro co:bog pe:lim al:tia rs:beg cl:scl ua:iev il:tlv ar:bue th:bkk ph:mnl"

RELAYS="$("$MULLVAD" relay list)"

ip_for() {   # $1=cc $2=cityCode -> first relay IPv4 for that city
  printf "%s\n" "$RELAYS" | awk -v cc="$1" -v code="$2" '
    $0 ~ "\\(" cc "\\)$" { inc=1; next }
    /^[A-Za-z].*\([a-z][a-z]\)$/ { inc=0 }
    inc && /^\t[A-Z]/ { city = ($0 ~ "\\(" code "\\)") ? 1 : 0 }
    inc && city && /^\t\t/ {
      if (match($0, /\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        print substr($0, RSTART+1, RLENGTH-1); exit
      }
    }'
}
name_for() {  # $1=cc $2=cityCode -> "City, ST" / "City"
  printf "%s\n" "$RELAYS" | awk -v cc="$1" -v code="$2" '
    $0 ~ "\\(" cc "\\)$" { inc=1; next }
    /^[A-Za-z].*\([a-z][a-z]\)$/ { inc=0 }
    inc && /^\t[A-Z]/ && $0 ~ "\\(" code "\\)" {
      c=$0; sub(/^\t/,"",c); sub(/ \(.*/,"",c); print c; exit
    }'
}

WAS_CONNECTED=0
"$MULLVAD" status | grep -q "^Connected" && WAS_CONNECTED=1
echo "Disconnecting Mullvad for direct measurement..." >&2
"$MULLVAD" disconnect >/dev/null 2>&1 || true
sleep 2

measure() {  # $1=cc $2=cityCode -> "cc|code|name|ip|ms"
  local cc="$1" code="$2" ip name min
  ip="$(ip_for "$cc" "$code")"; name="$(name_for "$cc" "$code")"
  if [ -z "$ip" ]; then echo "WARN: no relay for $cc/$code" >&2; return; fi
  min="$(ping -c 10 -i 0.2 -t 8 "$ip" 2>/dev/null | awk -F'= ' '/round-trip/{print $2}' | cut -d/ -f1)"
  [ -z "$min" ] && min=9999
  printf '%s|%s|%s|%s|%.0f\n' "$cc" "$code" "$name" "$ip" "$min"
}

US_ROWS=""; for code in $US_CITIES;    do US_ROWS+="$(measure us "$code")"$'\n'; done
NON_ROWS=""; for p in $NONUS_CITIES;   do NON_ROWS+="$(measure "${p%%:*}" "${p##*:}")"$'\n'; done

if [ "$WAS_CONNECTED" = 1 ]; then "$MULLVAD" connect >/dev/null 2>&1 || true; fi

mkdir -p "$(dirname "$OUT")"
GEN="$(date +%F)" python3 - "$US_ROWS" "$NON_ROWS" > "$OUT" <<'PY'
import os, sys, json
def parse(block):
    rows=[]
    for line in block.strip().splitlines():
        if not line.strip(): continue
        cc, code, name, ip, ms = line.split("|")
        rows.append({"city": name, "cc": cc, "cityCode": code, "ip": ip, "seedMs": int(float(ms))})
    rows.sort(key=lambda r: r["seedMs"])
    return rows
doc = {"generated": os.environ["GEN"], "us": parse(sys.argv[1]), "nonus": parse(sys.argv[2])}
print(json.dumps(doc, indent=2, ensure_ascii=False))
PY
echo "Wrote $OUT" >&2
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/refresh-candidates.sh
```

- [ ] **Step 3: Run it and verify output (this briefly drops the VPN, then reconnects)**

Run: `scripts/refresh-candidates.sh && python3 -c "import json; d=json.load(open('Resources/bundle/candidates.json')); print(len(d['us']),'us',len(d['nonus']),'nonus'); print(d['us'][0])"`
Expected: `6 us 15 nonus` and a Washington-DC-ish first US entry. Confirm Mullvad reconnected: `mullvad status | head -1` → `Connected`.

Note: this overwrites the Task 2 data file with fresh numbers — expected. If the diff is only latency drift, keep it; `git checkout Resources/bundle/candidates.json` to revert if you'd rather keep Task 2's snapshot.

- [ ] **Step 4: Commit (checkpoint)**

```bash
git add scripts/refresh-candidates.sh Resources/bundle/candidates.json
git commit -m "feat: refresh-candidates.sh to regenerate candidates.json"
```

---

### Task 7: Wire into the app (probe, sections, toggle) + build + docs

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5 (`loadCandidates`, `LatencyStore`, `fastCitiesMenu`, `toggleAction`, `parsePingMinRTT`) and `StatusItemKit.Shell`.
- Produces: the running feature. No new public API.

- [ ] **Step 1: Add the latency probe type**

In `Sources/VPNDNSMenuBar/main.swift`, after the imports and the `nsColor(_:)` function (before `final class App`), add:

```swift
/// Pings candidate relays and records direct latency — but ONLY while Mullvad is
/// off (pinging through the tunnel is unreliable). Runs off the main thread.
final class LatencyProbe {
    private let store: LatencyStore
    private let isOff: () -> Bool
    private let onUpdate: () -> Void
    private let queue = DispatchQueue(label: "vpndns.latency", attributes: .concurrent)
    private let gate = DispatchSemaphore(value: 8)   // max concurrent pings
    private var timer: Timer?
    private var running = false

    init(store: LatencyStore, isOff: @escaping () -> Bool, onUpdate: @escaping () -> Void) {
        self.store = store
        self.isOff = isOff
        self.onUpdate = onUpdate
    }

    func start(interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.probeIfOff()
        }
        probeIfOff()
    }

    /// Trigger a probe now if Mullvad is off and one isn't already running.
    func probeIfOff() {
        guard isOff(), !running else { return }
        running = true
        queue.async { [weak self] in self?.runProbe() }
    }

    private func runProbe() {
        defer { running = false }
        let relays = store.pool.us + store.pool.nonus
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [CityLatency] = []
        let now = Date()

        for relay in relays {
            gate.wait()
            group.enter()
            queue.async { [weak self] in
                defer { self?.gate.signal(); group.leave() }
                guard let self = self, self.isOff() else { return }
                let out = Shell.run("/sbin/ping", ["-c", "5", "-i", "0.2", "-t", "5", relay.ip]) ?? ""
                let ms = parsePingMinRTT(out) ?? 9999
                let direct = self.isOff()
                lock.lock()
                results.append(CityLatency(cityCode: relay.cityCode, ms: ms, measuredAt: now, direct: direct))
                lock.unlock()
            }
        }
        group.wait()

        // Only commit if still off and at least one direct result landed.
        guard isOff() else { return }
        let direct = results.filter { $0.direct }
        guard !direct.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.store.recordAll(direct)
            self?.onUpdate()
        }
    }
}
```

- [ ] **Step 2: Add store + probe properties and load them at launch**

In `final class App`, add stored properties next to the existing ones:

```swift
    private let store: LatencyStore
    private var probe: LatencyProbe!
```

Add an initializer (the class currently has none) right after those properties:

```swift
    override init() {
        let pool: CandidatePool
        if let url = Bundle.main.url(forResource: "candidates", withExtension: "json"),
           let loaded = try? loadCandidates(from: url) {
            pool = loaded
        } else {
            pool = CandidatePool(generated: "", us: [], nonus: [])
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VPNDNSMenuBar/latency.json")
        self.store = LatencyStore(pool: pool, fileURL: support)
        super.init()
    }
```

At the end of `applicationDidFinishLaunching(_:)`, after `controller.start()`, add:

```swift
        probe = LatencyProbe(
            store: store,
            isOff: { [weak self] in self?.mullvad.state == .off },
            onUpdate: { [weak self] in self?.controller.refreshMenu() }
        )
        probe.start(interval: 15 * 60)
```

> If `StatusItemController` has no `refreshMenu()`, replace the `onUpdate` body with `{}` — the menu rebuilds on next open anyway via `onBuildMenu`. (Verify in `../StatusItemKit/Sources/StatusItemKit/StatusItemController.swift`; only add a call that exists.)

- [ ] **Step 3: Trigger an opportunistic probe on connected→off transition**

In `poll()`, capture the previous state and fire a probe when the tunnel drops. Change:

```swift
    private func poll() {
        mullvad = parseMullvadStatus(Shell.run(MULLVAD, ["status"]) ?? "")
```

to:

```swift
    private func poll() {
        let previous = mullvad.state
        mullvad = parseMullvadStatus(Shell.run(MULLVAD, ["status"]) ?? "")
        if previous != .off && mullvad.state == .off { probe?.probeIfOff() }
```

- [ ] **Step 4: Render the two sections in `build(_:)`**

In `build(_:)`, after the Tailscale row block and its `menu.addItem(NSMenuItem.separator())`, and **before** the `Start at Login` item, insert:

```swift
        let model = fastCitiesMenu(store: store, currentRelay: mullvad.relay, now: Date())
        addFastSection(menu, model.us)
        addFastSection(menu, model.nonus)
        if !model.us.rows.isEmpty || !model.nonus.rows.isEmpty {
            let foot = NSMenuItem(title: model.footer, action: nil, keyEquivalent: "")
            foot.isEnabled = false
            menu.addItem(foot)
            menu.addItem(NSMenuItem.separator())
        }
```

Add these helper methods to `App` (next to `openMullvad`):

```swift
    private func addFastSection(_ menu: NSMenu, _ section: MenuSection) {
        guard !section.rows.isEmpty else { return }
        let header = NSMenuItem(title: section.header, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for row in section.rows {
            let item = NSMenuItem(title: row.title, action: #selector(toggleCity(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isCurrent ? .on : .off
            item.representedObject = ["cc": row.cc, "city": row.cityCode]
            menu.addItem(item)
        }
    }

    @objc private func toggleCity(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let cc = info["cc"], let city = info["city"] else { return }
        switch toggleAction(currentRelay: mullvad.relay, clickedCC: cc, clickedCityCode: city) {
        case .disconnect:
            _ = Shell.run(MULLVAD, ["disconnect"])
        case .connect(let cc, let city):
            _ = Shell.run(MULLVAD, ["relay", "set", "location", cc, city])
            _ = Shell.run(MULLVAD, ["connect"])
        }
        poll()
    }
```

- [ ] **Step 5: Build the unit tests + app**

Run: `swift test` (all green), then `scripts/build-app.sh`
Expected: tests pass; build prints `==> Built build/VPN & DNS.app`.

- [ ] **Step 6: Confirm the data file made it into the app bundle**

Run: `ls "build/VPN & DNS.app/Contents/Resources/candidates.json" && echo OK`
Expected: path listed + `OK`. (If missing, confirm the file is at `Resources/bundle/candidates.json` so `make-app.sh` copies it.)

- [ ] **Step 7: Manual verification (relaunch + click-through)**

```bash
pkill -f "VPN & DNS.app/Contents/MacOS/VPNDNSMenuBar" 2>/dev/null || true
open "build/VPN & DNS.app"
```
Then, by hand:
1. Click the menu-bar dot → confirm both sections appear with 3 cities each and the freshness footer.
2. Click a city you're not on (e.g. "Washington DC") → `mullvad status | head -1` shows `Connected` to a `us-was-…` relay; reopen menu → that row has a ✓.
3. Click the **same** city again → `mullvad status` shows disconnecting/off (toggle off).
4. Restore the user's pinned relay: `mullvad relay set location ca mtr ca-mtr-wg-001 && mullvad connect`.

- [ ] **Step 8: Update README**

In `README.md`, add a short subsection under the menu description documenting the two new sections, the toggle behavior, that latency is measured directly only while disconnected (seeded from `candidates.json`), and that `scripts/refresh-candidates.sh` regenerates the candidate list/seeds. Keep it to a short paragraph + the refresh command.

- [ ] **Step 9: Commit (checkpoint)**

```bash
git add Sources/VPNDNSMenuBar/main.swift README.md
git commit -m "feat: fastest No-ID city sections with toggle + latency probe"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** Two sections (Tasks 5, 7) ✓; US no-age-verif from No-ID lists (Task 2 data) ✓; non-US no-age-verif + torrent filter incl. NZ exclusion (Task 2 data, Task 6 script) ✓; click-to-toggle (Tasks 3, 7) ✓; dynamic/opportunistic-while-off probe (Task 7) ✓; cached + seeded + persisted (Tasks 2, 4) ✓; freshness footer (Task 5) ✓; refresh script (Task 6) ✓; tests (Tasks 1–5) ✓.
- **Deviation from spec:** data ships in `Resources/bundle/candidates.json` (copied by `make-app.sh`) instead of a SwiftPM resource, so **no `Package.swift` change** — see Global Constraints. Functionally identical, more robust for this repo's packaging.
- **Type consistency:** `CandidateRelay`/`CandidatePool` (Task 2) used identically in Tasks 4–5 and Task 7; `LatencyStore`/`Region`/`CityLatency` (Task 4) used identically in Task 5 and Task 7; `toggleAction`/`isCurrentCity` (Task 3) used in Tasks 5, 7; `parsePingMinRTT` (Task 1) used in Task 7. Section titles and row-title format match the Global Constraints verbatim.
- **Placeholders:** none — every code/data/command step is complete.
