import AppKit
import StatusItemKit
import VPNDNSCore

private let MULLVAD = "/usr/local/bin/mullvad"
private let TS = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
private let QBT_IFACE = "utun100"
private let QBT_DEVJSON = "/etc/wireguard-qbt/device.json"
private let QBT_GATEWAY = "10.64.0.1"

private func nsColor(_ c: DotColor) -> NSColor {
    switch c {
    case .green: return NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)   // #30d158
    case .orange: return NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)    // #ff9f0a
    case .red: return NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)       // #ff453a
    case .grey: return NSColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1)     // #98989d
    case .blue: return NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)      // #0a84ff
    }
}

/// Maximum-contrast text color: pure black in light mode, pure white in dark.
/// labelColor is ~85% alpha, which still reads washed-out for menu headers.
private let maxContrastColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
}

/// Non-clickable group header: bold at normal menu size and full contrast.
/// (The native macOS 14 sectionHeader style was tried and rejected — its
/// fixed small/muted rendering is exactly the hard-to-read look this avoids.)
private func headerItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize),
        .foregroundColor: maxContrastColor,
    ])
    return item
}

/// Small filled circle for menu-row status dots, centered in a 16 pt canvas
/// (the standard menu-item image slot).
private func dotImage(_ color: NSColor, diameter: CGFloat = 10) -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        let inset = (rect.width - diameter) / 2
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: diameter, height: diameter)).fill()
        return true
    }
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
        defer { DispatchQueue.main.async { [weak self] in self?.running = false } }
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
                guard let ms = parsePingMinRTT(out) else { return }   // failed ping: keep last-good/seed, don't clobber
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

final class App: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController!
    private var mullvad = MullvadStatus(state: .off, relay: nil, location: nil)
    private var backend = "Unknown"
    private var corpDNS = false
    private var qbtState: QbtTunnelState = .notInstalled
    private var qbtLastRelay: String?     // main-thread; last confirmed exit hostname
    private var pollTick = 0              // main-thread; drives the every-12th curl
    private var splitTunnel = SplitTunnelStatus(enabled: false, apps: [])
    private var qbtExitCandidates: [QbtExitCandidate] = []   // main-thread
    private let store: LatencyStore
    private var probe: LatencyProbe!
    private let mullvadStateLock = NSLock()
    private var mullvadIsOff = false   // guarded by mullvadStateLock; read by probe off-main
    private let pollQueue = DispatchQueue(label: "vpndns.poll")
    private var pollInFlight = false   // main-thread only; drops overlapping polls

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

    func applicationDidFinishLaunching(_ n: Notification) {
        controller = StatusItemController(
            pollInterval: 5,
            onPoll: { [weak self] in self?.poll() },
            onBuildMenu: { [weak self] menu in self?.build(menu) }
        )
        controller.start()
        probe = LatencyProbe(
            store: store,
            isOff: { [weak self] in
                guard let self = self else { return false }
                self.mullvadStateLock.lock()
                defer { self.mullvadStateLock.unlock() }
                return self.mullvadIsOff
            },
            // no-op: StatusItemController rebuilds the menu on each open, so fresh
            // latencies appear next time the menu is opened.
            onUpdate: { }
        )
        probe.start(interval: 15 * 60)
        // Crash backstop: a probe killed mid-run can leave /sbin/ping in the
        // split-tunnel exclusions; never let that linger across launches.
        DispatchQueue.global().async {
            let st = parseSplitTunnel(Shell.run(MULLVAD, ["split-tunnel", "get"]) ?? "")
            if st.apps.contains(probePingPath) {
                _ = Shell.run(MULLVAD, ["split-tunnel", "app", "remove", probePingPath])
            }
        }
    }

    // True iff the Tailscale GUI app is already running. We must NOT invoke the
    // Tailscale binary (`status` / `debug prefs`) when it isn't: with no running
    // instance, that binary LAUNCHES the Tailscale GUI, so polling it every 5s
    // silently re-opens Tailscale after the user has quit it. Checked on the main
    // thread (AppKit) and passed into the background poll.
    private func tailscaleAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "io.tailscale.ipn.macsys").isEmpty
    }

    // Invoked on the main thread by StatusItemController's timer. The blocking
    // `mullvad`/`tailscale` CLI calls run on a background queue so a slow or hung
    // subprocess can never freeze the run loop (a wedged main thread is exactly
    // what stops the status-item menu from opening on click); state + icon are
    // committed back on main, so build()/menuNeedsUpdate read only main-written
    // state and there's no data race. Overlapping ticks are dropped.
    private func poll() {
        if pollInFlight { return }
        pollInFlight = true
        let tsRunning = tailscaleAppRunning()   // on main; guards the GUI-launching calls below
        let tick = pollTick
        pollTick += 1
        let lastRelay = qbtLastRelay
        let needCandidates = qbtState != .notInstalled && (qbtExitCandidates.isEmpty || tick % 720 == 0)
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let mv = parseMullvadStatus(Shell.run(MULLVAD, ["status"]) ?? "")
            // Only query Tailscale when its app is already up — invoking the binary
            // while it's quit would relaunch the GUI. When down, report not running.
            let be = tsRunning ? parseTailscaleBackend(Shell.run(TS, ["status", "--json"]) ?? "") : "Not running"
            let dns = tsRunning ? parseCorpDNS(Shell.run(TS, ["debug", "prefs"]) ?? "") : false
            let qbt = self.pollQbtBlocking(tick: tick, lastRelay: lastRelay)
            let st = parseSplitTunnel(Shell.run(MULLVAD, ["split-tunnel", "get"]) ?? "")
            // Candidate cities for the exit switcher: hourly, or until first success.
            let candidates: [QbtExitCandidate]? = needCandidates
                ? parseQbtExitCandidates(Shell.run("/usr/local/libexec/qbt-tunnel/pin-qbt-relay.sh", ["--list"], timeout: 20) ?? "")
                : nil
            DispatchQueue.main.async {
                self.pollInFlight = false
                let previous = self.mullvad.state
                self.mullvad = mv
                self.backend = be
                self.corpDNS = dns
                self.qbtState = qbt.0
                self.qbtLastRelay = qbt.1
                self.splitTunnel = st
                if let candidates = candidates, !candidates.isEmpty {
                    self.qbtExitCandidates = candidates
                }
                self.mullvadStateLock.lock()
                self.mullvadIsOff = (mv.state == .off)
                self.mullvadStateLock.unlock()
                if previous != .off && mv.state == .off { self.probe?.probeIfOff() }
                self.controller.setIcon(MeterIcon.dot(color: nsColor(dotColor(mullvad: mv.state, tailscaleRunning: be == "Running"))))
            }
        }
    }

    // Runs on pollQueue (never main). Cheap local checks every tick; the exit-IP
    // curl only every 12th tick (~60s) or until a relay name is first learned.
    private func pollQbtBlocking(tick: Int, lastRelay: String?) -> (QbtTunnelState, String?) {
        guard let devJson = try? String(contentsOfFile: QBT_DEVJSON, encoding: .utf8),
              let dev = parseQbtDevice(devJson) else { return (.notInstalled, nil) }
        let ifOut = Shell.run("/sbin/ifconfig", [QBT_IFACE], timeout: 3) ?? ""
        let ifaceUp = parseIfconfigHasAddress(ifOut, address: dev.address)
        var alive = false
        if ifaceUp {
            let ping = Shell.run("/sbin/ping", ["-q", "-c", "1", "-t", "2", "-b", QBT_IFACE, QBT_GATEWAY], timeout: 4) ?? ""
            alive = parsePingMinRTT(ping) != nil
        }
        var relay = lastRelay
        if alive && (relay == nil || tick % 12 == 0) {
            // Ask through the proxy: that exercises the exact path qBittorrent uses.
            let json = Shell.run("/usr/bin/curl",
                ["--socks5-hostname", "127.0.0.1:1080", "--max-time", "4", "-s",
                 "https://am.i.mullvad.net/json"], timeout: 8) ?? ""
            if let fresh = parseExitHostname(json) { relay = fresh }
        }
        let proxyUp = parseProxyListening(
            Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:1080", "-sTCP:LISTEN"], timeout: 5) ?? "")
        let running = !(Shell.run("/usr/bin/pgrep", ["-x", "qbittorrent"], timeout: 3) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var usingProxy = false
        if running {
            let lsof = Shell.run("/usr/sbin/lsof",
                ["-nP", "-a", "-c", "qbittorre", "-iTCP", "-sTCP:ESTABLISHED"], timeout: 5) ?? ""
            usingProxy = parseQbtUsingProxy(lsof)
        }
        return (deriveQbtState(installed: true, ifaceUp: ifaceUp, alive: alive, proxyUp: proxyUp,
                               qbtRunning: running, qbtUsingProxy: usingProxy, relay: relay), relay)
    }

    private func addGroupHeader(_ menu: NSMenu, _ title: String) {
        menu.addItem(headerItem(title))
    }

    // Three headed groups: everything Mullvad (status, split tunnel, relay
    // pickers), the qbt tunnel (status dot + actions — its own section, though
    // the device is a Mullvad one), then everything Tailscale (status, toggle,
    // accept-dns — a Tailscale pref), then app items.
    private func build(_ menu: NSMenu) {
        addGroupHeader(menu, "Mullvad")

        let mv = NSMenuItem(title: mullvadRowLabel(mullvad), action: #selector(openMullvad), keyEquivalent: "")
        mv.target = self
        menu.addItem(mv)

        menu.addItem(buildSplitTunnelItem())

        let model = fastCitiesMenu(store: store, currentRelay: mullvad.relay, now: Date())
        if !model.us.rows.isEmpty { menu.addItem(fastCitiesSubmenuItem(model.us, footer: model.footer)) }
        if !model.nonus.rows.isEmpty { menu.addItem(fastCitiesSubmenuItem(model.nonus, footer: model.footer)) }

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

        menu.addItem(NSMenuItem.separator())
        addGroupHeader(menu, "Tailscale")

        let dns = NSMenuItem(title: acceptDNSLabel(corpDNS), action: #selector(toggleAcceptDNS), keyEquivalent: "")
        dns.target = self
        dns.image = dotImage(nsColor(acceptDNSDotColor(corpDNS)))
        menu.addItem(dns)

        let ts = NSMenuItem(title: tailscaleRowLabel(backend), action: #selector(openTailscale), keyEquivalent: "")
        ts.target = self
        menu.addItem(ts)

        let tsToggle = NSMenuItem(title: tailscaleToggleLabel(backend), action: #selector(toggleTailscale), keyEquivalent: "")
        tsToggle.target = self
        menu.addItem(tsToggle)

        menu.addItem(NSMenuItem.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

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

    // Open Mullvad's native popover by AX-clicking its status item (inlined from
    // assets/open-native-menu.sh). Needs Accessibility + Automation permission.
    @objc private func openMullvad() {
        _ = Shell.run("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to tell process \"Mullvad VPN\" to click menu bar item 1 of menu bar 2"])
    }
    @objc private func openTailscale() {
        _ = Shell.run("/usr/bin/open", ["-a", "Tailscale"])
    }
    @objc private func openQbt() {
        _ = Shell.run("/usr/bin/open", ["-a", "qbittorrent"])
    }
    @objc private func toggleTailscale() {
        let action = tailscaleToggle(backend)
        DispatchQueue.global().async { [weak self] in
            switch action {
            case .up: _ = Shell.run(TS, ["up"])
            case .down: _ = Shell.run(TS, ["down"])
            }
            DispatchQueue.main.async { self?.poll() }
        }
    }
    // Manual override; the DNS watcher (event-driven) re-asserts its mapping on
    // the next Mullvad connect/disconnect, so this holds only until then.
    @objc private func toggleAcceptDNS() {
        let target = corpDNS ? "false" : "true"
        DispatchQueue.global().async { [weak self] in
            _ = Shell.run(TS, ["set", "--accept-dns=\(target)"])
            DispatchQueue.main.async { self?.poll() }
        }
    }
    private func buildSplitTunnelItem() -> NSMenuItem {
        let root = NSMenuItem(title: splitTunnelMenuTitle(splitTunnel.enabled), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let toggle = NSMenuItem(title: splitTunnelToggleLabel(splitTunnel.enabled), action: #selector(toggleSplitTunnel), keyEquivalent: "")
        toggle.target = self
        sub.addItem(toggle)
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
        sub.addItem(NSMenuItem.separator())
        let add = NSMenuItem(title: "Add App…", action: #selector(addSplitTunnelApp), keyEquivalent: "")
        add.target = self
        sub.addItem(add)
        root.submenu = sub
        return root
    }

    private func buildQbtExitItem() -> NSMenuItem {
        let root = NSMenuItem(title: "qBittorrent Exit", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if qbtExitCandidates.isEmpty {
            sub.addItem(infoItem("Loading candidates…"))
        } else {
            for c in qbtExitCandidates {
                let item = NSMenuItem(title: c.display, action: #selector(switchQbtExit(_:)), keyEquivalent: "")
                item.target = self
                item.state = qbtExitIsCurrent(relay: qbtLastRelay, cityCode: c.code) ? .on : .off
                item.representedObject = c.code
                sub.addItem(item)
            }
        }
        sub.addItem(NSMenuItem.separator())
        let probe = NSMenuItem(title: "Re-probe & Pin Fastest", action: #selector(reprobeQbtExit), keyEquivalent: "")
        probe.target = self
        sub.addItem(probe)
        root.submenu = sub
        return root
    }

    @objc private func switchQbtExit(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        qbtLastRelay = nil   // stale once re-pinned; re-learned from am.i.mullvad on next poll
        DispatchQueue.global().async { [weak self] in
            _ = Shell.run("/usr/bin/sudo",
                ["-n", "/usr/local/libexec/qbt-tunnel/pin-qbt-relay.sh", "--city", code], timeout: 60)
            DispatchQueue.main.async { self?.poll() }
        }
    }

    @objc private func reprobeQbtExit() {
        qbtLastRelay = nil
        DispatchQueue.global().async { [weak self] in
            // Full latency sweep across ~22 cities; give it plenty of rope.
            _ = Shell.run("/usr/bin/sudo",
                ["-n", "/usr/local/libexec/qbt-tunnel/pin-qbt-relay.sh"], timeout: 300)
            DispatchQueue.main.async { self?.poll() }
        }
    }

    @objc private func toggleSplitTunnel() {
        let target = splitTunnel.enabled ? "off" : "on"
        DispatchQueue.global().async { [weak self] in
            _ = Shell.run(MULLVAD, ["split-tunnel", "set", target])
            DispatchQueue.main.async { self?.poll() }
        }
    }

    @objc private func removeSplitTunnelApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        DispatchQueue.global().async { [weak self] in
            _ = Shell.run(MULLVAD, ["split-tunnel", "app", "remove", path])
            DispatchQueue.main.async { self?.poll() }
        }
    }

    @objc private func addSplitTunnelApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // .app bundles resolve to their executable; bare binaries pass through.
        let path = Bundle(url: url)?.executableURL?.path ?? url.path
        DispatchQueue.global().async { [weak self] in
            _ = Shell.run(MULLVAD, ["split-tunnel", "app", "add", path])
            DispatchQueue.main.async { self?.poll() }
        }
    }

    // sudo -n: fail instead of prompting (a GUI app can't answer); the
    // /etc/sudoers.d/qbt-tunnel rule must match this command exactly.
    @objc private func restartQbtTunnel() {
        DispatchQueue.global().async { [weak self] in
            _ = Shell.run("/usr/bin/sudo",
                ["-n", "/bin/launchctl", "kickstart", "-k", "system/com.nicholassmith.qbt-wireguard"],
                timeout: 15)
            DispatchQueue.main.async { self?.poll() }
        }
    }
    @objc private func toggleLogin() { LoginItem.toggle() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
