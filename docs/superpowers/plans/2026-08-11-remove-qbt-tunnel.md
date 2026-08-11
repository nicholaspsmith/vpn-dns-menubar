# Remove qBittorrent Tunnel + Mullvad Device in Header — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Purge every trace of the qBittorrent dedicated tunnel from the repo, and make the Mullvad menu header name the device this machine is registered as (`Mullvad - Fair Sheep`).

**Architecture:** Pure subtraction in Tasks 1–2 — the qbt Core modules, their tests, the menu section, the tunnel teardown/restart/exit-switch actions, the `qbt-tunnel/` directory, and all documentation. Tasks 3–4 add one small pure parser (`parseMullvadDeviceName`) in `VPNDNSCore` plus a cached poll in `main.swift` that feeds the group header.

**Tech Stack:** Swift 5 / SwiftPM, AppKit, XCTest, StatusItemKit (sibling repo at `../StatusItemKit`), zsh, launchd.

**Spec:** `docs/superpowers/specs/2026-08-11-remove-qbt-tunnel-design.md`

## Global Constraints

- `swift build && swift test` must pass at the end of every task. Never commit red.
- The live system teardown (Part 1 of the spec) is **already done**: agent and daemon booted out, `utun100` gone, `/etc/wireguard-qbt` and `/etc/sudoers.d/qbt-tunnel` removed, device "Proper Gecko" revoked, and `set_qbt_tunnel()` already stripped from `dns-watcher/mullvad-tailscale-dns-sync.sh` (commit on branch `remove-qbt-tunnel`). Do not redo any of it.
- Branch is `remove-qbt-tunnel`. Commit after every task.
- Header separator is a literal `" - "`, exactly as requested — not an en dash.
- Logged-out or unparseable device output must render bare `Mullvad`, never an empty or malformed header.
- Historical specs and plans under `docs/superpowers/` keep their qbt references — they are the record. Only live code and user-facing docs get purged.
- The app rebuilds with `scripts/build-app.sh`, which requires the sibling repo `../StatusItemKit` to exist.

## File Structure

| Path | Responsibility after this plan |
| --- | --- |
| `Sources/VPNDNSCore/MullvadDevice.swift` | **New.** Pure parse of `mullvad account get` → device name. |
| `Tests/VPNDNSCoreTests/MullvadDeviceTests.swift` | **New.** Covers normal, logged-out, whitespace, multi-word, missing-line. |
| `Sources/VPNDNSMenuBar/main.swift` | Menu app. Loses ~130 lines of qbt surface; gains a `deviceName` poll and header title. |
| `Sources/VPNDNSCore/QbtTunnelStatus.swift`, `QbtExitCandidates.swift` | **Deleted.** All 14 symbols are used only by the qbt code paths (verified). |
| `Tests/VPNDNSCoreTests/QbtTunnelStatusTests.swift`, `QbtExitCandidatesTests.swift` | **Deleted.** |
| `qbt-tunnel/` | **Deleted** (9 files). |
| `install.sh`, `README.md`, `~/.claude/CLAUDE.md` | Documentation, minus qbt. |

Verified before writing this plan: `parsePingMinRTT` lives in `Latency.swift` and is still used by the latency probe at `main.swift:140`; `infoItem` is still used by the fast-cities footer at `main.swift:404`. Neither may be deleted.

---

### Task 1: Strip qbt from the menu app and delete its Core modules

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift`
- Delete: `Sources/VPNDNSCore/QbtTunnelStatus.swift`, `Sources/VPNDNSCore/QbtExitCandidates.swift`
- Delete: `Tests/VPNDNSCoreTests/QbtTunnelStatusTests.swift`, `Tests/VPNDNSCoreTests/QbtExitCandidatesTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a `main.swift` with no qbt references, whose `poll()` still increments `pollTick` (Task 4 reuses it) and whose `build()` still calls `addGroupHeader(menu, "Mullvad")` (Task 4 changes that argument).

- [ ] **Step 1: Delete the four qbt files**

```bash
git rm Sources/VPNDNSCore/QbtTunnelStatus.swift \
       Sources/VPNDNSCore/QbtExitCandidates.swift \
       Tests/VPNDNSCoreTests/QbtTunnelStatusTests.swift \
       Tests/VPNDNSCoreTests/QbtExitCandidatesTests.swift
```

- [ ] **Step 2: Run the build to see it fail**

Run: `swift build`
Expected: FAIL — `main.swift` references `QbtTunnelState`, `parseQbtDevice`, `qbtRowLabel` and friends, which no longer exist. This is the checklist for Step 3.

- [ ] **Step 3: Remove every qbt region from `main.swift`**

Delete the three constants at the top (keep `MULLVAD` and `TS`):

```swift
private let QBT_IFACE = "utun100"
private let QBT_DEVJSON = "/etc/wireguard-qbt/device.json"
private let QBT_GATEWAY = "10.64.0.1"
```

Delete these stored properties (keep `pollTick` — Task 4 needs it):

```swift
private var qbtState: QbtTunnelState = .notInstalled
private var qbtLastRelay: String?     // main-thread; last confirmed exit hostname
private var qbtExitCandidates: [QbtExitCandidate] = []   // main-thread
```

In `poll()`, delete the local `lastRelay`/`needCandidates` bindings, the `qbt` and `candidates` work, and their main-thread commits, so the body reads:

```swift
    private func poll() {
        if pollInFlight { return }
        pollInFlight = true
        let tsRunning = tailscaleAppRunning()   // on main; guards the GUI-launching calls below
        pollTick += 1
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let mv = parseMullvadStatus(Shell.run(MULLVAD, ["status"]) ?? "")
            // Only query Tailscale when its app is already up — invoking the binary
            // while it's quit would relaunch the GUI. When down, report not running.
            let be = tsRunning ? parseTailscaleBackend(Shell.run(TS, ["status", "--json"]) ?? "") : "Not running"
            let dns = tsRunning ? parseCorpDNS(Shell.run(TS, ["debug", "prefs"]) ?? "") : false
            let st = parseSplitTunnel(Shell.run(MULLVAD, ["split-tunnel", "get"]) ?? "")
            DispatchQueue.main.async {
                self.pollInFlight = false
                let previous = self.mullvad.state
                self.mullvad = mv
                self.backend = be
                self.corpDNS = dns
                self.splitTunnel = st
                self.mullvadStateLock.lock()
                self.mullvadIsOff = (mv.state == .off)
                self.mullvadStateLock.unlock()
                if previous != .off && mv.state == .off { self.probe?.probeIfNeeded() }
                // The evaluation in start() ran before any poll had committed real
                // state (mullvadIsOff/splitTunnel still init defaults → skip), so
                // re-evaluate once the first real state lands.
                if !self.firstPollCommitted {
                    self.firstPollCommitted = true
                    self.probe?.probeIfNeeded()
                }
                self.controller.setIcon(MeterIcon.dot(color: nsColor(dotColor(mullvad: mv.state, tailscaleRunning: be == "Running"))))
            }
        }
    }
```

Delete the whole `pollQbtBlocking(tick:lastRelay:)` method including its two-line comment above it.

Replace the group comment above `build()` — it describes a group that no longer exists:

```swift
    // Three headed groups: everything Mullvad (status, split tunnel, relay
    // pickers), then everything Tailscale (status, toggle, accept-dns — a
    // Tailscale pref), then app items.
```

Delete the qBittorrent section from `build()` entirely:

```swift
        if qbtState != .notInstalled {
            menu.addItem(NSMenuItem.separator())
            addGroupHeader(menu, "qBittorrent")
            let qbt = NSMenuItem(title: qbtRowLabel(qbtState), action: #selector(openQbt), keyEquivalent: "")
            qbt.target = self
            qbt.image = dotImage(nsColor(qbtDotColor(qbtState)))
            menu.addItem(qbt)
            let restart = NSMenuItem(title: "Restart qBittorrent Tunnel", action: #selector(restartQbtTunnel), keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
            menu.addItem(buildQbtExitItem())
        }
```

The `menu.addItem(NSMenuItem.separator())` that follows it stays — it is the divider before the Tailscale header.

In `toggleCity(_:)` and `toggleMullvad()`, drop the `qbtInstalled` binding and the teardown call, leaving the connect branches as bare `Shell.run` calls:

```swift
    @objc private func toggleCity(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let cc = info["cc"], let city = info["city"] else { return }
        let action = toggleAction(currentRelay: mullvad.relay, clickedCC: cc, clickedCityCode: city)
        DispatchQueue.global().async { [weak self] in
            switch action {
            case .disconnect:
                _ = Shell.run(MULLVAD, ["disconnect"])
            case .connect(let cc, let city):
                _ = Shell.run(MULLVAD, ["relay", "set", "location", cc, city])
                _ = Shell.run(MULLVAD, ["connect"])
            }
            DispatchQueue.main.async { self?.poll() }
        }
    }

    // Connect goes to Mullvad's persisted relay selection — no app-side copy
    // to go stale if the endpoint is changed in the native app.
    @objc private func toggleMullvad() {
        let action = mullvadToggle(mullvad.state)
        DispatchQueue.global().async { [weak self] in
            switch action {
            case .connect: _ = Shell.run(MULLVAD, ["connect"])
            case .disconnect: _ = Shell.run(MULLVAD, ["disconnect"])
            }
            DispatchQueue.main.async { self?.poll() }
        }
    }
```

Delete these five members outright, each including its comment block: `teardownQbtTunnelBlocking()`, `openQbt()`, `buildQbtExitItem()`, `switchQbtExit(_:)`, `reprobeQbtExit()`, and `restartQbtTunnel()`.

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: PASS. If the compiler reports an unused variable, a qbt local was missed — remove it rather than silencing it.

- [ ] **Step 5: Confirm no qbt symbols survive in code**

Run: `grep -rn -i "qbt\|qbittorrent" Sources/ Tests/`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add -A Sources Tests
git commit -m "refactor: remove the qBittorrent tunnel from the menu app

Deletes QbtTunnelStatus/QbtExitCandidates and their tests, the qBittorrent
menu section, the tunnel teardown/restart/exit-switch actions, and the
pre-connect teardown that only existed to keep utun100 from stuttering the
Mullvad handshake."
```

---

### Task 2: Delete `qbt-tunnel/` and purge the docs

**Files:**
- Delete: `qbt-tunnel/` (all 9 files)
- Modify: `install.sh`, `README.md`, `/Users/nicholassmith/.claude/CLAUDE.md`

**Interfaces:**
- Consumes: Task 1's clean `Sources/`.
- Produces: nothing code-facing.

- [ ] **Step 1: Delete the directory**

```bash
git rm -r qbt-tunnel/
```

- [ ] **Step 2: Purge `install.sh`**

Three hits. Line 5's header comment loses its parenthetical about exclusivity; line 33's echo becomes `echo "Loaded launchd agent $LABEL (accept-dns follows Mullvad state)."`; line 54's `sudo $SRC_DIR/qbt-tunnel/install-qbt-tunnel.sh` hint is deleted along with any now-dangling label line introducing it.

- [ ] **Step 3: Purge `README.md`**

Delete the entire `## qBittorrent dedicated tunnel` section, from that heading through the end of its `### Uninstall (qbt tunnel only)` block, stopping before the next top-level section. Then fix each remaining mention:
- the intro sentence describing the repo as covering a qBittorrent tunnel, and the watcher's "two duties" phrasing → one duty;
- the menu sketch's `qBittorrent` header, status row, `Restart qBittorrent Tunnel`, and `qBittorrent Exit ▸` lines;
- the dot-legend paragraph describing the grey/orange/green qBittorrent row;
- the watcher rows in the architecture/file table that mention exclusivity;
- the paragraph under the watcher section describing enforcement of exclusivity;
- the menu-features paragraph listing "the qBittorrent section".

- [ ] **Step 4: Update `~/.claude/CLAUDE.md`**

In the **DNS watcher** bullet, remove the "AND (since 2026-08-03) enforcing Mullvad/qbt-tunnel mutual exclusivity…" clause and the sudoers reference, leaving the accept-dns duty. Add one clause recording that the qbt tunnel was removed 2026-08-11 and that torrenting lives on `dino`.

- [ ] **Step 5: Verify the purge**

Run: `grep -rn -i "qbt\|qbittorrent" . --exclude-dir=.git --exclude-dir=.build --exclude-dir=docs`
Expected: no output.

Run: `swift build && swift test`
Expected: PASS (unchanged by docs, but confirms nothing was clipped).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: remove the qBittorrent tunnel from the repo and docs

Deletes qbt-tunnel/ and every README/install.sh reference. The design
record stays in docs/superpowers/."
```

---

### Task 3: `parseMullvadDeviceName` in VPNDNSCore (TDD)

**Files:**
- Create: `Sources/VPNDNSCore/MullvadDevice.swift`
- Test: `Tests/VPNDNSCoreTests/MullvadDeviceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public func parseMullvadDeviceName(_ raw: String) -> String?` — returns the trimmed device name, or `nil` when the line is absent or its value is empty. Task 4 calls this.

- [ ] **Step 1: Write the failing test**

Create `Tests/VPNDNSCoreTests/MullvadDeviceTests.swift`:

```swift
import XCTest
@testable import VPNDNSCore

final class MullvadDeviceTests: XCTestCase {
    func testLoggedIn() {
        let raw = """
        Mullvad account:    8991497502551539
        Expires at:         2026-10-02 14:44:31 -04:00
        Device name:        Fair Sheep
        """
        XCTAssertEqual(parseMullvadDeviceName(raw), "Fair Sheep")
    }

    func testLoggedOut() {
        XCTAssertNil(parseMullvadDeviceName("Not logged in on any account\n"))
    }

    func testMissingLineEntirely() {
        XCTAssertNil(parseMullvadDeviceName(""))
    }

    func testEmptyValueIsNil() {
        XCTAssertNil(parseMullvadDeviceName("Device name:        \n"))
    }

    func testTrailingWhitespaceTrimmed() {
        XCTAssertEqual(parseMullvadDeviceName("Device name:   Proper Gecko   \n"), "Proper Gecko")
    }

    func testAccountNumberIsNotConfusedForTheName() {
        let raw = """
        Mullvad account:    8991497502551539
        Device name:        Clear Turtle
        """
        XCTAssertEqual(parseMullvadDeviceName(raw), "Clear Turtle")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter MullvadDeviceTests`
Expected: FAIL to compile — `cannot find 'parseMullvadDeviceName' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/VPNDNSCore/MullvadDevice.swift`:

```swift
import Foundation

/// Parse `mullvad account get`. The device name is the value of the
/// `Device name:` line; everything else on the output (account number,
/// expiry) is ignored. Returns nil when logged out — that output carries no
/// such line — so callers can fall back to an unadorned label.
public func parseMullvadDeviceName(_ raw: String) -> String? {
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let r = line.range(of: "Device name:") else { continue }
        let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    return nil
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MullvadDeviceTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift build && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/VPNDNSCore/MullvadDevice.swift Tests/VPNDNSCoreTests/MullvadDeviceTests.swift
git commit -m "feat: parse the Mullvad device name from \`mullvad account get\`"
```

---

### Task 4: Show the device name in the Mullvad header

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift`

**Interfaces:**
- Consumes: `parseMullvadDeviceName(_:) -> String?` from Task 3; `pollTick` kept alive by Task 1.
- Produces: header text `Mullvad - <device>`, or `Mullvad` when unknown.

- [ ] **Step 1: Add the stored property**

Beside the other main-thread state in `final class App`:

```swift
    private var deviceName: String?   // main-thread; nil until first fetch, or when logged out
```

- [ ] **Step 2: Fetch it on the poll queue**

In `poll()`, restore the tick local and fetch the name at startup and every 12th tick (~60 s at the 5 s poll interval — the name only changes on login/logout, so this is generous):

```swift
        let tick = pollTick
        pollTick += 1
        let needDevice = deviceName == nil || tick % 12 == 0
```

Inside the `pollQueue.async` block, alongside the other CLI calls:

```swift
            let device: String? = needDevice
                ? parseMullvadDeviceName(Shell.run(MULLVAD, ["account", "get"], timeout: 5) ?? "")
                : nil
```

And in the main-thread commit, only overwrite when this tick actually fetched — so a skipped tick never blanks a good name:

```swift
                if needDevice { self.deviceName = device }
```

- [ ] **Step 3: Use it in the header**

In `build()`, replace `addGroupHeader(menu, "Mullvad")` with:

```swift
        addGroupHeader(menu, deviceName.map { "Mullvad - \($0)" } ?? "Mullvad")
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: PASS.

- [ ] **Step 5: Verify against the real CLI**

Run: `mullvad account get`
Expected: a `Device name:` line — on this machine, `Fair Sheep`.

Run: `scripts/build-app.sh && open "build/VPN & DNS.app"`
Expected: the menu's first row reads `Mullvad - Fair Sheep`, there is no qBittorrent section, and the Mullvad, split-tunnel, fast-cities and Tailscale rows all still work. Give it ~5 s after launch for the first poll to land before opening the menu.

- [ ] **Step 6: Commit**

```bash
git add Sources/VPNDNSMenuBar/main.swift
git commit -m "feat: show the registered Mullvad device in the menu header

Two Macs shared one device for months without anything surfacing it; the
header now names the device this machine is registered as."
```

---

## Self-Review

**Spec coverage.** Part 1 live teardown — already executed, recorded under Global Constraints. Part 1 repo surgery — Tasks 1 and 2 cover every row of the spec's table, including the watcher (done earlier on this branch) and CLAUDE.md. Part 2 — Tasks 3 and 4 cover the parser, its tests, the poll cadence, the fallback, and the literal `" - "` separator. Spec verification items map to Task 1 Step 5, Task 2 Step 5, and Task 4 Step 5; the post-change flap observation is explicitly not a gate.

**Placeholders.** None — every code step carries the actual code, and the two doc-editing steps enumerate each hit to fix rather than saying "update the docs".

**Type consistency.** `parseMullvadDeviceName(_ raw: String) -> String?` is defined in Task 3 and called with that exact signature in Task 4. `deviceName: String?`, `pollTick`, `needDevice`, and `addGroupHeader(_:_:)` are consistent across Tasks 1 and 4. `pollTick` is deliberately preserved by Task 1 Step 3 and consumed by Task 4 Step 2.
