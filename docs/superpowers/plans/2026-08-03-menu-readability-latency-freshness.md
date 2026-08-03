# Menu Readability + Latency Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Legible non-clickable menu items (native section headers + full-contrast info rows), fast-cities sections as top-5 submenus, and a 12-hour latency freshness policy that can probe even while Mullvad is connected via a split-tunnel-excluded `/sbin/ping`.

**Architecture:** Pure decision logic (staleness check, probe decision, display filter, top-N) lives in `VPNDNSCore` and is unit-tested; AppKit menu construction and Mullvad CLI calls stay in the app target (`Sources/VPNDNSMenuBar/main.swift`), consistent with the existing split. `LatencyProbe` gains a second probe mode that temporarily adds `/sbin/ping` to Mullvad's split-tunnel exclusions (never touching the on/off state), verifies the exclusion before and after pinging, and always removes it.

**Tech Stack:** Swift 5.9 SPM package, AppKit (`NSMenuItem`), XCTest, Mullvad CLI (`/usr/local/bin/mullvad`), StatusItemKit (unchanged).

**Spec:** `docs/superpowers/specs/2026-08-02-menu-readability-design.md` — read it before starting.

## Global Constraints

- Platform floor is **macOS 13** (`Package.swift` `platforms: [.macOS(.v13)]`): any macOS 14+ API must be behind `#available(macOS 14.0, *)` with a working fallback.
- **Never run `mullvad split-tunnel set on|off` from probe code.** Only the user's menu toggle (`toggleSplitTunnel`) may change that state. Probe code may only `app add` / `app remove` the ping binary.
- **Never record a through-tunnel measurement.** `direct: true` requires Mullvad off, or a verified-active `/sbin/ping` exclusion — checked both before pinging and again at commit time.
- The excluded binary path is the single core constant `probePingPath` (`"/sbin/ping"`); never inline the string in the app target.
- Mullvad CLI is the existing file-private constant `MULLVAD` (`/usr/local/bin/mullvad`) in `main.swift`; reuse it.
- All work happens on branch `feature/qbt-dedicated-tunnel` (the qBittorrent menu rows this touches exist only there).
- Run `swift test` from the repo root; every test must pass before every commit.
- Every commit message ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01TArqdHYmZwAMrRJiYdPcTX`
- Semantic colors only (`NSColor.labelColor` / `.secondaryLabelColor`) — no hard-coded text colors.

---

### Task 1: Manual spike — does an excluded `/sbin/ping` really bypass the tunnel?

**Files:** none created/modified (except a spike-result note appended to the spec).

**Interfaces:**
- Consumes: nothing.
- Produces: a go/no-go decision for Task 7's `.probeViaSplitTunnel` path, recorded in the spec.

**⚠️ Requires the user present.** This spike connects Mullvad and briefly enables split tunneling (activating their ~13 configured excluded apps for ~2 minutes) — both user-visible state changes. Ask for an explicit go-ahead first; if the user is unavailable, do Tasks 2–6 first and return here before Task 7. Note: the user's `ssh dino` sessions (Tailscale-only) break while Mullvad is connected.

- [ ] **Step 1: Ask the user for a go-ahead**, explaining: Mullvad will connect, split tunneling will be on for ~2 minutes (their exclusion list active), then everything is restored exactly as found.

- [ ] **Step 2: Record current state** (to restore later):

```bash
mullvad status
mullvad split-tunnel get   # note: state on|off; whether /sbin/ping is present (it should not be)
```

- [ ] **Step 3: Pick a test relay IP** — take one US entry from `Resources/bundle/candidates.json` (fields: `city`, `ip`, `seedMs`). Note its `seedMs` (the expected *direct* RTT) and, if `~/Library/Application Support/VPNDNSMenuBar/latency.json` exists, its measured value.

- [ ] **Step 4: Connect and take a through-tunnel baseline:**

```bash
mullvad connect && sleep 5 && mullvad status   # wait for "Connected"
ping -c 3 <relay-ip>                            # note min RTT (or note if blocked)
```

- [ ] **Step 5: Enable exclusion and re-ping:**

```bash
mullvad split-tunnel set on          # spike only — the feature itself never does this
mullvad split-tunnel app add /sbin/ping
mullvad split-tunnel get             # must show: state on, /sbin/ping listed
ping -c 3 <relay-ip>                 # note min RTT
```

**PASS:** `app add` succeeded AND the step-5 RTT is close to the known direct value (`seedMs`/latency.json) and clearly different from the step-4 baseline (or step 4 was blocked and step 5 works). **FAIL:** `app add` refuses `/sbin/ping`, or RTT is unchanged from the tunnel baseline, or pings are blocked with the exclusion active.

- [ ] **Step 6: Restore everything recorded in step 2:**

```bash
mullvad split-tunnel app remove /sbin/ping
mullvad split-tunnel set off         # only if it was off in step 2
mullvad disconnect                   # only if it was disconnected in step 2
mullvad split-tunnel get && mullvad status   # confirm restored
```

- [ ] **Step 7: Record the outcome** — append a short dated "Spike result (2026-08-03)" note (commands run, RTTs observed, PASS/FAIL) to the end of `docs/superpowers/specs/2026-08-02-menu-readability-design.md`, then commit:

```bash
git add docs/superpowers/specs/2026-08-02-menu-readability-design.md
git commit -m "docs: spike result — split-tunnel-excluded ping"
```

- [ ] **Step 8: Decision gate.** PASS → proceed with the plan as written. FAIL → **STOP and consult the user**; the fallback is the 12-hour staleness rule for off-probes only (Task 7 without the `.probeViaSplitTunnel` arm, `probeDecision` returning `.skip` for the connected case), but the user decides.

---

### Task 2: Core — top 5 cities per section

**Files:**
- Modify: `Sources/VPNDNSCore/FastCities.swift:80` (the `topN` default)
- Test: `Tests/VPNDNSCoreTests/FastCitiesMenuTests.swift`

**Interfaces:**
- Consumes: existing `fastCitiesMenu(store:currentRelay:now:topN:)`, `CandidatePool`, `CandidateRelay(city:cc:cityCode:ip:seedMs:)`, `LatencyStore(pool:)`.
- Produces: `fastCitiesMenu` defaulting to `topN: Int = 5`. No signature change — callers are unaffected.

- [ ] **Step 1: Update the existing top-3 test and add a cap test.** In `FastCitiesMenuTests.swift`, rename `testSectionsHeadersAndTopThreeTitles` → `testSectionsHeadersAndTopFiveTitles` and change its row assertions — the fixture pool has 4 US / 3 non-US relays, and with a default of 5 all of them appear, sorted by latency:

```swift
    func testSectionsHeadersAndTopFiveTitles() {
        let s = LatencyStore(pool: menuPool())
        let m = fastCitiesMenu(store: s, currentRelay: nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.us.header, "Fastest US (No-ID)")
        XCTAssertEqual(m.nonus.header, "Fastest Non-US (No-ID · torrent-safe)")
        XCTAssertEqual(m.us.rows.map { $0.title },
                       ["Washington DC — 25 ms", "Secaucus, NJ — 28 ms", "Boston, MA — 35 ms",
                        "Seattle, WA — 73 ms"])
        XCTAssertEqual(m.nonus.rows.map { $0.title },
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
        XCTAssertEqual(m.us.rows.map { $0.cityCode }, ["aaa", "bbb", "ccc", "ddd", "eee"])
        XCTAssertTrue(m.nonus.rows.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail:**

Run: `swift test --filter FastCitiesMenuTests`
Expected: `testSectionsHeadersAndTopFiveTitles` FAILS (only 3 US rows) and `testTopFiveCapsAtFive` FAILS (3 rows, not 5).

- [ ] **Step 3: Change the default.** In `Sources/VPNDNSCore/FastCities.swift` line 80:

```swift
public func fastCitiesMenu(store: LatencyStore, currentRelay: String?, now: Date,
                           topN: Int = 5) -> FastCitiesMenu {
```

- [ ] **Step 4: Run the full suite to verify everything passes:**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 5: Commit:**

```bash
git add Sources/VPNDNSCore/FastCities.swift Tests/VPNDNSCoreTests/FastCitiesMenuTests.swift
git commit -m "feat: top-5 fastest cities per section (was top-3)"
```

---

### Task 3: Core — staleness check + probe decision

**Files:**
- Modify: `Sources/VPNDNSCore/Latency.swift` (append at end of file)
- Test: Create `Tests/VPNDNSCoreTests/ProbePolicyTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Tasks 4, 7, 8):

```swift
public func isLatencyStale(last: Date?, now: Date, maxAge: TimeInterval) -> Bool
public enum ProbeDecision: Equatable { case probeDirect, probeViaSplitTunnel, skip }
public func probeDecision(stale: Bool, mullvadOff: Bool, splitTunnelOn: Bool) -> ProbeDecision
public let probePingPath: String   // "/sbin/ping"
```

- [ ] **Step 1: Write the failing tests** — create `Tests/VPNDNSCoreTests/ProbePolicyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify they fail to compile** (symbols don't exist yet):

Run: `swift test --filter ProbePolicyTests`
Expected: BUILD FAILURE — `cannot find 'isLatencyStale' in scope` (and friends).

- [ ] **Step 3: Implement** — append to `Sources/VPNDNSCore/Latency.swift`:

```swift
/// True when there is no direct measurement yet, or the newest one is older
/// than `maxAge`. Exactly `maxAge` old still counts as fresh.
public func isLatencyStale(last: Date?, now: Date, maxAge: TimeInterval) -> Bool {
    guard let last = last else { return true }
    return now.timeIntervalSince(last) > maxAge
}

/// How (whether) to probe right now.
public enum ProbeDecision: Equatable {
    case probeDirect            // Mullvad off: plain pings are direct
    case probeViaSplitTunnel    // connected, split tunneling already on: exclude the ping binary
    case skip
}

/// Fresh data never probes. Stale + connected probes only via split-tunnel
/// exclusion, and only when the user already has split tunneling on — the
/// probe never flips that state itself.
public func probeDecision(stale: Bool, mullvadOff: Bool, splitTunnelOn: Bool) -> ProbeDecision {
    guard stale else { return .skip }
    if mullvadOff { return .probeDirect }
    return splitTunnelOn ? .probeViaSplitTunnel : .skip
}

/// The binary temporarily excluded from the tunnel during connected probes.
public let probePingPath = "/sbin/ping"
```

- [ ] **Step 4: Run the full suite:**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 5: Commit:**

```bash
git add Sources/VPNDNSCore/Latency.swift Tests/VPNDNSCoreTests/ProbePolicyTests.swift
git commit -m "feat: staleness check + probe decision for 12h freshness policy"
```

---

### Task 4: Core — hide the probe's ping exclusion from the display list

**Files:**
- Modify: `Sources/VPNDNSCore/SplitTunnel.swift` (append at end of file)
- Test: `Tests/VPNDNSCoreTests/SplitTunnelTests.swift` (append)

**Interfaces:**
- Consumes: `probePingPath` (Task 3).
- Produces (used by Task 8): `public func splitTunnelDisplayApps(_ apps: [String]) -> [String]`

- [ ] **Step 1: Write the failing test** — append inside the existing test class in `Tests/VPNDNSCoreTests/SplitTunnelTests.swift`:

```swift
    func testDisplayAppsHidesProbePing() {
        XCTAssertEqual(
            splitTunnelDisplayApps(["/Applications/Arc.app/Contents/MacOS/Arc", "/sbin/ping"]),
            ["/Applications/Arc.app/Contents/MacOS/Arc"])
        XCTAssertEqual(splitTunnelDisplayApps(["/sbin/ping"]), [])
        XCTAssertEqual(splitTunnelDisplayApps([]), [])
    }
```

- [ ] **Step 2: Run to verify it fails to compile:**

Run: `swift test --filter SplitTunnelTests`
Expected: BUILD FAILURE — `cannot find 'splitTunnelDisplayApps' in scope`.

- [ ] **Step 3: Implement** — append to `Sources/VPNDNSCore/SplitTunnel.swift`:

```swift
/// Excluded apps to *display* in the menu: hides the app's own transient
/// probe exclusion (`probePingPath`), which is plumbing, not a user choice.
public func splitTunnelDisplayApps(_ apps: [String]) -> [String] {
    apps.filter { $0 != probePingPath }
}
```

- [ ] **Step 4: Run the full suite:**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 5: Commit:**

```bash
git add Sources/VPNDNSCore/SplitTunnel.swift Tests/VPNDNSCoreTests/SplitTunnelTests.swift
git commit -m "feat: hide the probe's transient /sbin/ping exclusion from display"
```

---

### Task 5: App — native section headers + full-contrast info rows

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift` (helpers near `nsColor` at the top; call sites at lines ~232-236, ~254-256, ~260-262, ~280-282, ~296-298, ~351-353, ~375-377)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (used by Task 6): file-private `func headerItem(_ title: String) -> NSMenuItem` and `func infoItem(_ title: String) -> NSMenuItem`, free functions in `main.swift`.

- [ ] **Step 1: Add the two helpers** as file-private free functions right after `nsColor` (they don't need `self`):

```swift
/// Non-clickable group header: the native section-header style on macOS 14+,
/// emulated (small bold, secondary color) on macOS 13.
private func headerItem(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) {
        return NSMenuItem.sectionHeader(title: title)
    }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ])
    return item
}

/// Non-clickable info row at full contrast: reads like content, never
/// highlights, takes no click. (An explicit attributedTitle overrides
/// AppKit's faint disabled-gray rendering.)
private func infoItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: NSFont.menuFont(ofSize: 0),
        .foregroundColor: NSColor.labelColor,
    ])
    return item
}
```

- [ ] **Step 2: Replace every "create item + `isEnabled = false`" site:**

`addGroupHeader` (lines 232-236) becomes:

```swift
    private func addGroupHeader(_ menu: NSMenu, _ title: String) {
        menu.addItem(headerItem(title))
    }
```

The footer in `build()` (lines 253-257) becomes:

```swift
        if !model.us.rows.isEmpty || !model.nonus.rows.isEmpty {
            menu.addItem(infoItem(model.footer))
        }
```

The qBittorrent status row (lines 260-262) becomes:

```swift
            menu.addItem(infoItem(qbtRowLabel(qbtState)))
```

The Accept-DNS row (lines 280-282) becomes:

```swift
        menu.addItem(infoItem(acceptDNSLabel(corpDNS)))
```

The section header in `addFastSection` (lines 296-298) becomes:

```swift
        menu.addItem(headerItem(section.header))
```

The split-tunnel submenu header (lines 350-353) becomes:

```swift
            sub.addItem(NSMenuItem.separator())
            sub.addItem(headerItem("Excluded from VPN — click to remove"))
```

The qBittorrent-exit placeholder (lines 374-377) becomes:

```swift
        if qbtExitCandidates.isEmpty {
            sub.addItem(infoItem("Loading candidates…"))
        } else {
```

After this step, `main.swift` must contain **no remaining** `isEnabled = false` outside the two helpers — verify with `grep -n "isEnabled = false" Sources/VPNDNSMenuBar/main.swift` (expect exactly the 2 helper occurrences).

- [ ] **Step 3: Build and test:**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 4: Rebuild the app and eyeball it:**

```bash
scripts/build-app.sh
pkill -x VPNDNSMenuBar || true
open ~/Applications/"VPN & DNS.app"
```

Open the menu: "Mullvad" and "Tailscale" render as native small/bold section headers; the qBittorrent status, Accept DNS, footer, and (if visible) "Loading candidates…" rows are full-contrast and do not highlight on hover; "Excluded from VPN — click to remove" in the Split Tunnel submenu is a section header. Check in both light and dark mode (System Settings → Appearance, or just confirm semantic colors render legibly in the current mode).

- [ ] **Step 5: Commit:**

```bash
git add Sources/VPNDNSMenuBar/main.swift
git commit -m "feat: native section headers + full-contrast info rows in menu"
```

---

### Task 6: App — fast-cities submenus with the footer inside

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift` (`build()` lines ~250-257; delete `addFastSection` lines ~294-306; add one method)

**Interfaces:**
- Consumes: `headerItem`/`infoItem` (Task 5 — `infoItem` only), existing `fastCitiesMenu`, `MenuSection`, `toggleCity(_:)`.
- Produces: private method `func fastCitiesSubmenuItem(_ section: MenuSection, footer: String) -> NSMenuItem` on `App`.

- [ ] **Step 1: Add the submenu builder** as a private method on `App` (next to `buildSplitTunnelItem`) — it needs `self` for the selector target:

```swift
    // One top-level item per fastest-cities section; city rows + freshness
    // footer live in its submenu so the top level stays short.
    private func fastCitiesSubmenuItem(_ section: MenuSection, footer: String) -> NSMenuItem {
        let root = NSMenuItem(title: section.header, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for row in section.rows {
            let item = NSMenuItem(title: row.title, action: #selector(toggleCity(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isCurrent ? .on : .off
            item.representedObject = ["cc": row.cc, "city": row.cityCode]
            sub.addItem(item)
        }
        sub.addItem(NSMenuItem.separator())
        sub.addItem(infoItem(footer))
        root.submenu = sub
        return root
    }
```

- [ ] **Step 2: Rewire `build()`** — replace the section+footer block (currently `addFastSection(menu, model.us)`, `addFastSection(menu, model.nonus)`, and the `if !model.us.rows.isEmpty || ...` footer block) with:

```swift
        let model = fastCitiesMenu(store: store, currentRelay: mullvad.relay, now: Date())
        if !model.us.rows.isEmpty { menu.addItem(fastCitiesSubmenuItem(model.us, footer: model.footer)) }
        if !model.nonus.rows.isEmpty { menu.addItem(fastCitiesSubmenuItem(model.nonus, footer: model.footer)) }
```

- [ ] **Step 3: Delete `addFastSection` entirely** (lines ~294-306). Verify nothing references it: `grep -n addFastSection Sources/VPNDNSMenuBar/main.swift` → no matches.

- [ ] **Step 4: Build and test:**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 5: Rebuild the app and eyeball it:**

```bash
scripts/build-app.sh
pkill -x VPNDNSMenuBar || true
open ~/Applications/"VPN & DNS.app"
```

The top level now shows "Fastest US (No-ID) ▸" and "Fastest Non-US (No-ID · torrent-safe) ▸" instead of inline city lists; each submenu shows up to 5 cities (checkmark on the current one when connected) with the "measured …" footer at the bottom; clicking a city still toggles the VPN.

- [ ] **Step 6: Commit:**

```bash
git add Sources/VPNDNSMenuBar/main.swift
git commit -m "feat: fast-cities sections become submenus with footer inside"
```

---

### Task 7: App — 12-hour freshness policy + connected probe via split-tunnel exclusion

**Only proceed on a Task 1 PASS** (otherwise consult the user; see Task 1 step 8).

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift` — `LatencyProbe` (lines ~21-85), its construction in `applicationDidFinishLaunching` (lines ~126-138), and the off-transition hook (line ~192)

**Interfaces:**
- Consumes: `isLatencyStale`, `ProbeDecision`, `probeDecision`, `probePingPath` (Task 3); existing `parseSplitTunnel`, `Shell.run`, `MULLVAD`, `LatencyStore`.
- Produces: `LatencyProbe.init(store:isOff:splitTunnelOn:onUpdate:)` and `func probeIfNeeded()` (replaces `probeIfOff()`).

- [ ] **Step 1: Rework `LatencyProbe`.** Replace the class wholesale with:

```swift
/// Pings candidate relays and records direct latency, at most every ~12 h
/// (the staleness ceiling). Two probe modes, chosen by `probeDecision`:
/// Mullvad off → plain pings are direct; Mullvad connected → only if the
/// user already has split tunneling on, by temporarily excluding
/// `/sbin/ping` from the tunnel (never flipping split-tunnel state itself).
/// Runs off the main thread.
final class LatencyProbe {
    private let store: LatencyStore
    private let isOff: () -> Bool
    private let splitTunnelOn: () -> Bool
    private let onUpdate: () -> Void
    private let queue = DispatchQueue(label: "vpndns.latency", attributes: .concurrent)
    private let gate = DispatchSemaphore(value: 8)   // max concurrent pings
    private var timer: Timer?
    private var running = false
    static let maxAge: TimeInterval = 12 * 3600

    init(store: LatencyStore, isOff: @escaping () -> Bool,
         splitTunnelOn: @escaping () -> Bool, onUpdate: @escaping () -> Void) {
        self.store = store
        self.isOff = isOff
        self.splitTunnelOn = splitTunnelOn
        self.onUpdate = onUpdate
    }

    func start(interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.probeIfNeeded()
        }
        probeIfNeeded()
    }

    /// Main thread. Probe iff the newest direct measurement is missing or
    /// older than 12 h, and the current state permits a trustworthy probe.
    func probeIfNeeded() {
        guard !running else { return }
        let stale = isLatencyStale(last: store.lastDirectMeasurement, now: Date(), maxAge: Self.maxAge)
        switch probeDecision(stale: stale, mullvadOff: isOff(), splitTunnelOn: splitTunnelOn()) {
        case .skip:
            return
        case .probeDirect:
            running = true
            queue.async { [weak self] in self?.runProbe(viaSplitTunnel: false) }
        case .probeViaSplitTunnel:
            running = true
            queue.async { [weak self] in self?.runProbe(viaSplitTunnel: true) }
        }
    }

    private func runProbe(viaSplitTunnel: Bool) {
        defer { DispatchQueue.main.async { [weak self] in self?.running = false } }

        if viaSplitTunnel {
            // add + verify; on any doubt, clean up and bail (retry next tick).
            _ = Shell.run(MULLVAD, ["split-tunnel", "app", "add", probePingPath])
            let st = parseSplitTunnel(Shell.run(MULLVAD, ["split-tunnel", "get"]) ?? "")
            guard st.enabled, st.apps.contains(probePingPath) else {
                _ = Shell.run(MULLVAD, ["split-tunnel", "app", "remove", probePingPath])
                return
            }
        }

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
                guard let self = self else { return }
                if !viaSplitTunnel && !self.isOff() { return }   // tunnel came up mid-probe
                let out = Shell.run("/sbin/ping", ["-c", "5", "-i", "0.2", "-t", "5", relay.ip]) ?? ""
                guard let ms = parsePingMinRTT(out) else { return }   // failed ping: keep last-good/seed
                lock.lock()
                results.append(CityLatency(cityCode: relay.cityCode, ms: ms, measuredAt: now, direct: true))
                lock.unlock()
            }
        }
        group.wait()

        // Commit-time re-verification (same rigor as the old isOff() re-check),
        // then ALWAYS remove our transient exclusion.
        let trustworthy: Bool
        if viaSplitTunnel {
            let st = parseSplitTunnel(Shell.run(MULLVAD, ["split-tunnel", "get"]) ?? "")
            trustworthy = st.enabled && st.apps.contains(probePingPath)
            _ = Shell.run(MULLVAD, ["split-tunnel", "app", "remove", probePingPath])
        } else {
            trustworthy = isOff()
        }
        guard trustworthy, !results.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.store.recordAll(results)
            self?.onUpdate()
        }
    }
}
```

(Behavior notes: the old per-ping `direct = self.isOff()` refinement is subsumed — a batch whose conditions degraded is discarded wholesale by the commit-time check, so surviving batches are all-direct. `recordAll` was already filtered to direct-only results in the old code; here every recorded result is `direct: true` by construction.)

- [ ] **Step 2: Update the construction site** in `applicationDidFinishLaunching` (~line 126). `splitTunnelOn` reads main-thread poll state — safe because `probeIfNeeded` only runs on main (timer + off-transition hook):

```swift
        probe = LatencyProbe(
            store: store,
            isOff: { [weak self] in
                guard let self = self else { return false }
                self.mullvadStateLock.lock()
                defer { self.mullvadStateLock.unlock() }
                return self.mullvadIsOff
            },
            // Main-thread read: probeIfNeeded only ever runs on the main thread.
            splitTunnelOn: { [weak self] in self?.splitTunnel.enabled ?? false },
            // no-op: StatusItemController rebuilds the menu on each open, so fresh
            // latencies appear next time the menu is opened.
            onUpdate: { }
        )
        probe.start(interval: 15 * 60)
```

(The 15-minute timer stays — it is now just the *evaluation* cadence; probing happens at most every 12 h.)

- [ ] **Step 3: Update the off-transition hook** at line ~192:

```swift
                if previous != .off && mv.state == .off { self.probe?.probeIfNeeded() }
```

Verify no `probeIfOff` references remain: `grep -n probeIfOff Sources/VPNDNSMenuBar/main.swift` → no matches.

- [ ] **Step 4: Build and test:**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 5: Verify the two user-independent scenarios** (Mullvad stays off — no user coordination needed):

Scenario A — stale + off → probes:

```bash
scripts/build-app.sh
pkill -x VPNDNSMenuBar || true
rm -f ~/Library/Application\ Support/VPNDNSMenuBar/latency.json
open ~/Applications/"VPN & DNS.app"
sleep 45
stat -f "%Sm" ~/Library/Application\ Support/VPNDNSMenuBar/latency.json   # exists, timestamped now
```

Menu footer (inside either fast-cities submenu) reads "measured just now (direct)".

Scenario B — fresh → skips:

```bash
pkill -x VPNDNSMenuBar; sleep 1
open ~/Applications/"VPN & DNS.app"
sleep 45
stat -f "%Sm" ~/Library/Application\ Support/VPNDNSMenuBar/latency.json   # mtime UNCHANGED from scenario A
```

- [ ] **Step 6: Commit:**

```bash
git add Sources/VPNDNSMenuBar/main.swift
git commit -m "feat: 12h latency freshness; connected probes via split-tunnel exclusion"
```

---

### Task 8: App — startup crash cleanup + filtered split-tunnel display

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift` — `applicationDidFinishLaunching` (~line 119) and `buildSplitTunnelItem` (~lines 349-361)

**Interfaces:**
- Consumes: `probePingPath` (Task 3), `splitTunnelDisplayApps` (Task 4), existing `parseSplitTunnel`, `Shell.run`, `MULLVAD`.
- Produces: nothing consumed later.

- [ ] **Step 1: Startup cleanup.** At the end of `applicationDidFinishLaunching`, after `probe.start(interval: 15 * 60)`:

```swift
        // Crash backstop: a probe killed mid-run can leave /sbin/ping in the
        // split-tunnel exclusions; never let that linger across launches.
        DispatchQueue.global().async {
            let st = parseSplitTunnel(Shell.run(MULLVAD, ["split-tunnel", "get"]) ?? "")
            if st.apps.contains(probePingPath) {
                _ = Shell.run(MULLVAD, ["split-tunnel", "app", "remove", probePingPath])
            }
        }
```

- [ ] **Step 2: Filter the displayed exclusions.** In `buildSplitTunnelItem`, filter once at the top of the excluded-apps block and use the filtered list for both the emptiness check and the loop:

```swift
        let apps = splitTunnelDisplayApps(splitTunnel.apps)
        if !apps.isEmpty {
            sub.addItem(NSMenuItem.separator())
            sub.addItem(headerItem("Excluded from VPN — click to remove"))
            for path in apps {
                let item = NSMenuItem(title: splitTunnelAppDisplayName(path), action: #selector(removeSplitTunnelApp(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.representedObject = path
                item.toolTip = path
                sub.addItem(item)
            }
        }
```

- [ ] **Step 3: Build and test:**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 4: Verify the cleanup end-to-end** (safe with Mullvad off — the exclusion list is inert while disconnected and while split tunneling is off):

```bash
mullvad split-tunnel app add /sbin/ping    # simulate a crashed probe's leftover
scripts/build-app.sh
pkill -x VPNDNSMenuBar || true
open ~/Applications/"VPN & DNS.app"
sleep 5
mullvad split-tunnel get                   # /sbin/ping must be GONE
```

Also open Split Tunnel in the menu — the excluded-apps list shows the user's apps only (and while `/sbin/ping` was present it would not have been listed).

- [ ] **Step 5: Commit:**

```bash
git add Sources/VPNDNSMenuBar/main.swift
git commit -m "feat: startup cleanup of probe exclusion + filtered split-tunnel display"
```

---

### Task 9: Docs + final verification (connected scenarios need the user)

**Files:**
- Modify: `README.md:37-48` (menu description + latency paragraph)

**Interfaces:**
- Consumes: everything built above.
- Produces: nothing.

- [ ] **Step 1: Update README.** Rewrite lines 37-48 to describe: the two fastest-city **submenus** (top-5, checkmark, footer inside each); the section-header/info-row styling is cosmetic — no need to document it beyond removing stale claims; and replace the latency paragraph's "only while Mullvad is disconnected" with the new policy. Suggested replacement for the two paragraphs:

```markdown
Below the Mullvad row the menu shows two **fastest-city submenus**:
"Fastest US (No-ID)" and "Fastest Non-US (No-ID · torrent-safe)" — the top-5 cities
from the candidate list ranked by latency. Clicking a city connects Mullvad to that
city (setting the relay location then running `mullvad connect`); clicking the
currently-active city disconnects (toggle behavior). A checkmark (✓) marks the city
you're connected to. A freshness footer at the bottom of each submenu shows when
the latencies were last measured.

Latency is re-measured by direct ICMP pings (`/sbin/ping`) when the newest
measurement is older than **12 hours**: normally while Mullvad is disconnected;
if Mullvad is connected and split tunneling is already on, the app temporarily
adds `/sbin/ping` to the split-tunnel exclusions so pings bypass the tunnel,
then removes it (it never turns split tunneling on or off itself, and hides the
transient exclusion from the Split Tunnel submenu). On first run, and until a
live measurement completes, the app falls back to seed values baked into
`Resources/bundle/candidates.json`. Measurements persist across restarts in
`~/Library/Application Support/VPNDNSMenuBar/latency.json`.
```

Keep the `scripts/refresh-candidates.sh` block that follows. Also check the sample menu layout near the top of the README (lines ~20-31) and update it if it still shows inline city rows.

- [ ] **Step 2: Verify the connected scenarios — with the user** (Mullvad state changes; get a go-ahead, same caveats as Task 1):

Scenario C — stale + connected + split tunneling on → probes via exclusion:

```bash
pkill -x VPNDNSMenuBar || true
rm -f ~/Library/Application\ Support/VPNDNSMenuBar/latency.json
mullvad connect && sleep 5
mullvad split-tunnel set on
open ~/Applications/"VPN & DNS.app"
sleep 10 && mullvad split-tunnel get      # during the probe: /sbin/ping listed
sleep 45 && mullvad split-tunnel get      # after: /sbin/ping gone
stat -f "%Sm" ~/Library/Application\ Support/VPNDNSMenuBar/latency.json   # fresh
```

Footer reads "measured just now (direct)". Sanity-check a few values in `latency.json` against known direct RTTs (not all inflated by the tunnel hop).

Scenario D — stale + connected + split tunneling off → waits:

```bash
pkill -x VPNDNSMenuBar || true
rm -f ~/Library/Application\ Support/VPNDNSMenuBar/latency.json
mullvad split-tunnel set off
open ~/Applications/"VPN & DNS.app"
sleep 45
ls ~/Library/Application\ Support/VPNDNSMenuBar/latency.json   # must NOT exist
mullvad split-tunnel get                                        # /sbin/ping never added
```

Footer reads "measured: seed values". Then restore the user's state (`mullvad disconnect` etc. — whatever was recorded before the scenario).

- [ ] **Step 3: Full-suite + visual sweep.** `swift test` all green; open the menu in light and dark mode and re-confirm the Task 5/6 visual checklist end-to-end.

- [ ] **Step 4: Commit:**

```bash
git add README.md
git commit -m "docs: README — top-5 submenus, 12h freshness, connected probing"
```

- [ ] **Step 5: Done.** Report back with the superpowers:finishing-a-development-branch skill in mind (the branch also carries the unmerged qbt-tunnel work — integration is the user's call).
