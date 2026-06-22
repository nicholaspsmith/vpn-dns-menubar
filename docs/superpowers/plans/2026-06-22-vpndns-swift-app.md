# VPN & DNS menu-bar app (Swift) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the `vpn-dns-control.5s.sh` SwiftBar plugin into a standalone Swift menu-bar app (`VPNDNSMenuBar`, bundle "VPN & DNS.app") built on StatusItemKit, with all parsing in a pure, unit-tested `VPNDNSCore` library.

**Architecture:** SwiftPM package at the repo root with three targets: `VPNDNSCore` (pure parsing, no AppKit), `VPNDNSMenuBar` (executable; AppKit + StatusItemKit + VPNDNSCore), and `VPNDNSCoreTests`. The app polls `mullvad`/`tailscale` every 5s via `Shell.run`, parses with Core, renders a status dot via `MeterIcon.dot`, and builds a 3-row menu lazily. The existing SwiftBar plugin and the `dns-watcher` launchd agent stay in place untouched.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, StatusItemKit v0.1.0 (local path), macOS 13+.

## Global Constraints

- Work on a feature branch: `git checkout -b swift-app` before any change. Do **not** modify `vpn-dns-control.5s.sh`, `assets/`, or `dns-watcher/` — the plugin keeps working until parity.
- Platform floor **macOS 13** (`platforms: [.macOS(.v13)]`).
- StatusItemKit dependency via **local path**: `.package(path: "../StatusItemKit")`.
- Bundle: `CFBundleName` = "VPN & DNS", `CFBundleExecutable` = `VPNDNSMenuBar`, `CFBundleIdentifier` = `com.nicholaspsmith.VPNDNSMenuBar`, `LSUIElement` = true.
- Tool paths (match the plugin): mullvad `/usr/local/bin/mullvad`, Tailscale CLI `/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/usr/bin/open`, `/usr/bin/osascript`.
- Git: atomic commits per task; messages end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Reference for parsing behavior: `vpn-dns-control.5s.sh` lines 30–62 (state gather + color mapping) and 76–94 (dropdown rows).

## Live output formats (use verbatim for fixtures)

```
# /usr/local/bin/mullvad status   (disconnected)
Disconnected
    Visible location:       United States, Charleston. IPv4: 67.39.147.85

# /usr/local/bin/mullvad status   (connected — shape per plugin awk)
Connected
    Relay:                  us-bos-wg-001
    Visible location:       United States, Boston. IPv4: 1.2.3.4

# Tailscale status --json     ->   line:   "BackendState": "Stopped",
# Tailscale debug prefs       ->   line:   "CorpDNS": true,
```

---

### Task 1: Package skeleton + MullvadStatus parsing

**Files:**
- Create: `Package.swift`
- Create: `Sources/VPNDNSCore/MullvadStatus.swift`
- Test: `Tests/VPNDNSCoreTests/MullvadStatusTests.swift`

**Interfaces:**
- Produces:
  - `enum MullvadState: String { case connected, connecting, disconnecting, blocked, off }`
  - `struct MullvadStatus { let state: MullvadState; let relay: String?; let location: String? }`
  - `func parseMullvadStatus(_ raw: String) -> MullvadStatus`
- Parsing rules (from plugin lines 30–33, 44–49): state = first word of the first line, lowercased, mapped (`Connected`→`.connected`, `Connecting`→`.connecting`, `Disconnecting`→`.disconnecting`, `Blocked`→`.blocked`, anything else → `.off`). `relay` = text after `Relay:` (trimmed), nil if absent. `location` = text after `Visible location:` (trimmed), nil if absent.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VPNDNSMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VPNDNSMenuBar", targets: ["VPNDNSMenuBar"]),
        .library(name: "VPNDNSCore", targets: ["VPNDNSCore"]),
    ],
    dependencies: [
        .package(path: "../StatusItemKit"),
    ],
    targets: [
        .target(name: "VPNDNSCore"),
        .executableTarget(
            name: "VPNDNSMenuBar",
            dependencies: ["VPNDNSCore", .product(name: "StatusItemKit", package: "StatusItemKit")]
        ),
        .testTarget(name: "VPNDNSCoreTests", dependencies: ["VPNDNSCore"]),
    ]
)
```

- [ ] **Step 2: Write the failing test** `Tests/VPNDNSCoreTests/MullvadStatusTests.swift`

```swift
import XCTest
@testable import VPNDNSCore

final class MullvadStatusTests: XCTestCase {
    func testDisconnected() {
        let raw = """
        Disconnected
            Visible location:       United States, Charleston. IPv4: 67.39.147.85
        """
        let s = parseMullvadStatus(raw)
        XCTAssertEqual(s.state, .off)
        XCTAssertNil(s.relay)
        XCTAssertEqual(s.location, "United States, Charleston. IPv4: 67.39.147.85")
    }

    func testConnected() {
        let raw = """
        Connected
            Relay:                  us-bos-wg-001
            Visible location:       United States, Boston. IPv4: 1.2.3.4
        """
        let s = parseMullvadStatus(raw)
        XCTAssertEqual(s.state, .connected)
        XCTAssertEqual(s.relay, "us-bos-wg-001")
        XCTAssertEqual(s.location, "United States, Boston. IPv4: 1.2.3.4")
    }

    func testBlockedAndConnecting() {
        XCTAssertEqual(parseMullvadStatus("Blocked\n").state, .blocked)
        XCTAssertEqual(parseMullvadStatus("Connecting to ...\n").state, .connecting)
        XCTAssertEqual(parseMullvadStatus("Disconnecting...\n").state, .disconnecting)
    }
}
```

- [ ] **Step 3: Run, verify fail**

Run: `swift test --filter MullvadStatusTests`
Expected: FAIL — `parseMullvadStatus` undefined.

- [ ] **Step 4: Implement `Sources/VPNDNSCore/MullvadStatus.swift`**

```swift
import Foundation

public enum MullvadState: String {
    case connected, connecting, disconnecting, blocked, off
}

public struct MullvadStatus: Equatable {
    public let state: MullvadState
    public let relay: String?
    public let location: String?
}

/// Parse `mullvad status`. State is the first word of the first line; Relay and
/// Visible location are pulled from their labelled lines if present.
public func parseMullvadStatus(_ raw: String) -> MullvadStatus {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let firstWord = lines.first?.trimmingCharacters(in: .whitespaces)
        .split(separator: " ").first.map(String.init) ?? ""
    let state: MullvadState
    switch firstWord {
    case "Connected": state = .connected
    case "Connecting": state = .connecting
    case "Disconnecting": state = .disconnecting
    case "Blocked": state = .blocked
    default: state = .off
    }

    func value(after label: String) -> String? {
        for line in lines {
            if let r = line.range(of: label) {
                return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    return MullvadStatus(state: state, relay: value(after: "Relay:"), location: value(after: "Visible location:"))
}
```

- [ ] **Step 5: Run, verify pass**

Run: `swift test --filter MullvadStatusTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/VPNDNSCore/MullvadStatus.swift Tests/VPNDNSCoreTests/MullvadStatusTests.swift
git commit -m "feat: package skeleton + Mullvad status parsing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Tailscale parsing (BackendState + CorpDNS)

**Files:**
- Create: `Sources/VPNDNSCore/TailscaleStatus.swift`
- Test: `Tests/VPNDNSCoreTests/TailscaleStatusTests.swift`

**Interfaces:**
- Produces:
  - `func parseTailscaleBackend(_ json: String) -> String` — value of the first `"BackendState": "..."` line, or `"Unknown"` if absent.
  - `func parseCorpDNS(_ prefs: String) -> Bool` — value of the first `"CorpDNS": true|false` line, false if absent.

- [ ] **Step 1: Write the failing test** `Tests/VPNDNSCoreTests/TailscaleStatusTests.swift`

```swift
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
```

- [ ] **Step 2: Run, verify fail** — `swift test --filter TailscaleStatusTests` → FAIL.

- [ ] **Step 3: Implement `Sources/VPNDNSCore/TailscaleStatus.swift`**

```swift
import Foundation

/// First `"BackendState": "X"` value from `tailscale status --json`, else "Unknown".
public func parseTailscaleBackend(_ json: String) -> String {
    for line in json.split(separator: "\n") {
        guard line.contains("\"BackendState\"") else { continue }
        let parts = line.split(separator: "\"")
        // ... "BackendState" : "Running" ,  -> tokens: [.., BackendState, .., Running, ..]
        if let idx = parts.firstIndex(of: "BackendState"), idx + 2 < parts.count {
            return String(parts[idx + 2])
        }
    }
    return "Unknown"
}

/// First `"CorpDNS": true|false` from `tailscale debug prefs`, else false.
public func parseCorpDNS(_ prefs: String) -> Bool {
    for line in prefs.split(separator: "\n") where line.contains("\"CorpDNS\"") {
        return line.contains("true")
    }
    return false
}
```

- [ ] **Step 4: Run, verify pass** — `swift test --filter TailscaleStatusTests` → PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/VPNDNSCore/TailscaleStatus.swift Tests/VPNDNSCoreTests/TailscaleStatusTests.swift
git commit -m "feat: Tailscale BackendState + CorpDNS parsing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Presentation model (colors + row labels)

**Files:**
- Create: `Sources/VPNDNSCore/VPNPresentation.swift`
- Test: `Tests/VPNDNSCoreTests/VPNPresentationTests.swift`

**Interfaces:**
- Produces:
  - `enum DotColor { case green, orange, red, grey }` (pure; the app maps to NSColor)
  - `func dotColor(for: MullvadState) -> DotColor` — connected→green, connecting/disconnecting→orange, blocked→red, off→grey (plugin lines 44–49).
  - `func mullvadRowLabel(_ s: MullvadStatus) -> String` — "Mullvad: Connected — <relay>" when connected, else "Mullvad: <Word>[ — <location>]" (plugin lines 86–90). Word is the capitalized state ("Off" for `.off`).
  - `func acceptDNSLabel(_ on: Bool) -> String` — "accept-dns (MagicDNS): ON" / "OFF".
  - `func tailscaleRowLabel(_ backend: String) -> String` — "Tailscale: <backend>".
  - `func tailscaleColor(_ backend: String) -> DotColor` — Running→green, NeedsLogin/Starting→orange, else grey (plugin lines 57–62).

- [ ] **Step 1: Write the failing test** `Tests/VPNDNSCoreTests/VPNPresentationTests.swift`

```swift
import XCTest
@testable import VPNDNSCore

final class VPNPresentationTests: XCTestCase {
    func testDotColor() {
        XCTAssertEqual(dotColor(for: .connected), .green)
        XCTAssertEqual(dotColor(for: .connecting), .orange)
        XCTAssertEqual(dotColor(for: .blocked), .red)
        XCTAssertEqual(dotColor(for: .off), .grey)
    }
    func testMullvadRowLabel() {
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .connected, relay: "us-bos-wg-001", location: "X")),
            "Mullvad: Connected — us-bos-wg-001"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: "United States")),
            "Mullvad: Off — United States"
        )
        XCTAssertEqual(
            mullvadRowLabel(MullvadStatus(state: .off, relay: nil, location: nil)),
            "Mullvad: Off"
        )
    }
    func testOtherLabels() {
        XCTAssertEqual(acceptDNSLabel(true), "accept-dns (MagicDNS): ON")
        XCTAssertEqual(acceptDNSLabel(false), "accept-dns (MagicDNS): OFF")
        XCTAssertEqual(tailscaleRowLabel("Running"), "Tailscale: Running")
        XCTAssertEqual(tailscaleColor("Running"), .green)
        XCTAssertEqual(tailscaleColor("Stopped"), .grey)
    }
}
```

- [ ] **Step 2: Run, verify fail** — FAIL (undefined).

- [ ] **Step 3: Implement `Sources/VPNDNSCore/VPNPresentation.swift`**

```swift
import Foundation

public enum DotColor: Equatable { case green, orange, red, grey }

public func dotColor(for state: MullvadState) -> DotColor {
    switch state {
    case .connected: return .green
    case .connecting, .disconnecting: return .orange
    case .blocked: return .red
    case .off: return .grey
    }
}

private func word(_ state: MullvadState) -> String {
    switch state {
    case .connected: return "Connected"
    case .connecting: return "Connecting"
    case .disconnecting: return "Disconnecting"
    case .blocked: return "Blocked"
    case .off: return "Off"
    }
}

public func mullvadRowLabel(_ s: MullvadStatus) -> String {
    if s.state == .connected {
        return "Mullvad: Connected — \(s.relay ?? "?")"
    }
    if let loc = s.location, !loc.isEmpty {
        return "Mullvad: \(word(s.state)) — \(loc)"
    }
    return "Mullvad: \(word(s.state))"
}

public func acceptDNSLabel(_ on: Bool) -> String {
    "accept-dns (MagicDNS): \(on ? "ON" : "OFF")"
}

public func tailscaleRowLabel(_ backend: String) -> String { "Tailscale: \(backend)" }

public func tailscaleColor(_ backend: String) -> DotColor {
    switch backend {
    case "Running": return .green
    case "NeedsLogin", "Starting": return .orange
    default: return .grey
    }
}
```

- [ ] **Step 4: Run, verify pass** — PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/VPNDNSCore/VPNPresentation.swift Tests/VPNDNSCoreTests/VPNPresentationTests.swift
git commit -m "feat: VPN presentation model (colors + row labels)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: App target — status dot, menu, polling (build + manual verify)

**Files:**
- Create: `Sources/VPNDNSMenuBar/main.swift`
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`

**Interfaces:**
- Consumes: all of `VPNDNSCore`; `StatusItemKit` (`Shell`, `StatusItemController`, `MeterIcon`, `LoginItem`).

- [ ] **Step 1: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>VPNDNSMenuBar</string>
    <key>CFBundleIdentifier</key><string>com.nicholaspsmith.VPNDNSMenuBar</string>
    <key>CFBundleName</key><string>VPN &amp; DNS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Write `scripts/build-app.sh`**

```bash
#!/bin/bash
# Build VPN & DNS.app via StatusItemKit's shared make-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../StatusItemKit/scripts/make-app.sh VPNDNSMenuBar "VPN & DNS"
```

Then `chmod +x scripts/build-app.sh`.

- [ ] **Step 3: Write `Sources/VPNDNSMenuBar/main.swift`**

```swift
import AppKit
import StatusItemKit
import VPNDNSCore

private let MULLVAD = "/usr/local/bin/mullvad"
private let TS = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

private func nsColor(_ c: DotColor) -> NSColor {
    switch c {
    case .green: return NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)   // #30d158
    case .orange: return NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)    // #ff9f0a
    case .red: return NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)       // #ff453a
    case .grey: return NSColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1)     // #98989d
    }
}

final class App: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController!
    private var mullvad = MullvadStatus(state: .off, relay: nil, location: nil)
    private var backend = "Unknown"
    private var corpDNS = false

    func applicationDidFinishLaunching(_ n: Notification) {
        controller = StatusItemController(
            pollInterval: 5,
            onPoll: { [weak self] in self?.poll() },
            onBuildMenu: { [weak self] menu in self?.build(menu) }
        )
        controller.start()
    }

    private func poll() {
        mullvad = parseMullvadStatus(Shell.run(MULLVAD, ["status"]) ?? "")
        backend = parseTailscaleBackend(Shell.run(TS, ["status", "--json"]) ?? "")
        corpDNS = parseCorpDNS(Shell.run(TS, ["debug", "prefs"]) ?? "")
        controller.setIcon(MeterIcon.dot(color: nsColor(dotColor(for: mullvad.state))))
    }

    private func build(_ menu: NSMenu) {
        let dns = NSMenuItem(title: acceptDNSLabel(corpDNS), action: nil, keyEquivalent: "")
        dns.isEnabled = false
        menu.addItem(dns)
        menu.addItem(NSMenuItem.separator())

        let mv = NSMenuItem(title: mullvadRowLabel(mullvad), action: #selector(openMullvad), keyEquivalent: "")
        mv.target = self
        menu.addItem(mv)

        let ts = NSMenuItem(title: tailscaleRowLabel(backend), action: #selector(openTailscale), keyEquivalent: "")
        ts.target = self
        menu.addItem(ts)

        menu.addItem(NSMenuItem.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Open Mullvad's native popover by AX-clicking its status item (inlined from
    // assets/open-native-menu.sh). Needs Accessibility + Automation permission.
    @objc private func openMullvad() {
        _ = Shell.run("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to tell process \"Mullvad VPN\" to click menu bar item 1 of menu bar 2"])
    }
    @objc private func openTailscale() {
        _ = Shell.run("/usr/bin/open", ["-a", "Tailscale"])
    }
    @objc private func toggleLogin() { LoginItem.toggle() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Build the app bundle**

Run: `./scripts/build-app.sh`
Expected: `Built build/VPN & DNS.app`.

- [ ] **Step 5: Run the Core tests**

Run: `swift test`
Expected: all VPNDNSCore tests PASS.

- [ ] **Step 6: Manual verification** (AppKit glue has no unit tests)

Run: `open "build/VPN & DNS.app"`. Verify:
- A colored dot appears in the menu bar (grey when Mullvad disconnected, green when connected).
- Clicking shows: "accept-dns (MagicDNS): ON/OFF" (disabled), separator, "Mullvad: …" row, "Tailscale: …" row, "Start at Login", "Quit".
- Clicking the Mullvad row opens Mullvad's native popover (after granting Accessibility/Automation permission to "VPN & DNS" when prompted).
- Clicking the Tailscale row opens the Tailscale app.
- Quit exits.

Then quit: `pkill -x VPNDNSMenuBar`.

- [ ] **Step 7: Commit**

```bash
git add Sources/VPNDNSMenuBar/main.swift Resources/Info.plist scripts/build-app.sh
git commit -m "feat: VPNDNSMenuBar app (dot, 3-row menu, polling)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: README note + .gitignore

**Files:**
- Modify: `README.md` (add a "Standalone Swift app" section)
- Create/Modify: `.gitignore` (add `.build/`, `build/`, `*.app`, `.swiftpm/`)

- [ ] **Step 1: Append to `README.md`** a short section: the repo now also ships a standalone Swift app (`VPNDNSMenuBar`) built on [StatusItemKit](https://github.com/nicholaspsmith/StatusItemKit); build with `./scripts/build-app.sh`, `open "build/VPN & DNS.app"`; it needs Accessibility + Automation permission for the Mullvad row. The SwiftBar plugin remains available; the launchd DNS-sync agent is unchanged and shared.

- [ ] **Step 2: Ensure `.gitignore`** contains:

```
.build/
build/
*.app
.swiftpm/
```

- [ ] **Step 3: Commit**

```bash
git add README.md .gitignore
git commit -m "docs: note the standalone Swift app

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review checklist (run before reporting done)

- `swift test` green; `./scripts/build-app.sh` produces `build/VPN & DNS.app`.
- Plugin (`vpn-dns-control.5s.sh`), `assets/`, `dns-watcher/` untouched (`git status` shows only new Swift files + README/.gitignore).
- All work on the `swift-app` branch.
