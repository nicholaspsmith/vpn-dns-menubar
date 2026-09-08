import AppKit
import StatusItemKit
import VPNDNSCore

private let MULLVAD = "/usr/local/bin/mullvad"
private let TS = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
// The Tailscale CLI requires TERM (or TERM_PROGRAM) in its environment: without
// one it takes a launch-the-GUI path that fails with "The Tailscale GUI failed
// to start" printed to STDOUT with exit 0 — which parses as backend "Unknown".
// A login-launched app inherits neither var, so every TS call must inject one.
private let TS_ENV = ["TERM": "dumb"]

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
                guard let ms = parsePingMinRTT(out) else { return }   // failed ping: keep last-good/seed, don't clobber
                lock.lock()
                results.append(CityLatency(cityCode: relay.cityCode, ms: ms, measuredAt: now, direct: true))
                lock.unlock()
            }
        }
        group.wait()

        // Commit-time re-verification (same rigor as the old isOff() re-check):
        // a batch whose conditions degraded mid-probe is discarded wholesale.
        // Then ALWAYS remove our transient exclusion.
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

final class App: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController!
    /// Steps this icon aside while Curtain reveals the hidden block — the bar has
    /// no spare room, so a reveal borrows slots from the apps that cooperate.
    /// Restores itself on a timer if Curtain goes away mid-reveal.
    private var yieldClient: YieldClient!
    private var mullvad = MullvadStatus(state: .off, relay: nil, location: nil)
    private var backend = "Unknown"
    private var corpDNS = false
    private var deviceName: String?       // main-thread; nil until first fetch, or when logged out
    private var pollTick = 0              // main-thread; paces the device-name refresh
    private var splitTunnel = SplitTunnelStatus(enabled: false, apps: [])
    private let store: LatencyStore
    private var probe: LatencyProbe!
    private let mullvadStateLock = NSLock()
    private var mullvadIsOff = false   // guarded by mullvadStateLock; read by probe off-main
    private let pollQueue = DispatchQueue(label: "vpndns.poll")
    private var pollInFlight = false   // main-thread only; drops overlapping polls
    private var firstPollCommitted = false   // main-thread; gates the launch-time probe check

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
        yieldClient = YieldClient(item: controller)
        yieldClient.start()
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
        // The device name only changes on login/logout: fetch once at startup,
        // then every 12th tick (~60s at the 5s poll interval).
        let needDevice = deviceName == nil || tick % 12 == 0
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let mv = parseMullvadStatus(Shell.run(MULLVAD, ["status"]) ?? "")
            // Only query Tailscale when its app is already up — invoking the binary
            // while it's quit would relaunch the GUI. When down, report not running.
            let be = tsRunning ? parseTailscaleBackend(Shell.run(TS, ["status", "--json"], env: TS_ENV) ?? "") : "Not running"
            let dns = tsRunning ? parseCorpDNS(Shell.run(TS, ["debug", "prefs"], env: TS_ENV) ?? "") : false
            let st = parseSplitTunnel(Shell.run(MULLVAD, ["split-tunnel", "get"]) ?? "")
            let device: String? = needDevice
                ? parseMullvadDeviceName(Shell.run(MULLVAD, ["account", "get"], timeout: 5) ?? "")
                : nil
            DispatchQueue.main.async {
                self.pollInFlight = false
                let previous = self.mullvad.state
                self.mullvad = mv
                self.backend = be
                self.corpDNS = dns
                self.splitTunnel = st
                // Only overwrite on a tick that actually fetched, so a skipped
                // tick never blanks a good name.
                if needDevice { self.deviceName = device }
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
                self.lastIconColor = nsColor(dotColor(mullvad: mv.state, tailscaleRunning: be == "Running"))
                self.applyIcon()
            }
        }
    }

    // MARK: - Icon style

    /// The dot, or the chameleon that changes to the same colours. Persisted.
    enum IconStyle: String, CaseIterable {
        case chameleon, dot
        var title: String { self == .dot ? "Dot" : "Chameleon" }
        private static let key = "iconStyle"
        static var current: IconStyle {
            get { UserDefaults.standard.string(forKey: key).flatMap(IconStyle.init) ?? .chameleon }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    private var lastIconColor: NSColor = NSColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1)

    private func applyIcon() {
        switch IconStyle.current {
        case .chameleon: controller.setIcon(CharacterIcon.chameleon(color: lastIconColor))
        case .dot: controller.setIcon(MeterIcon.dot(color: lastIconColor))
        }
    }

    @objc private func setIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = IconStyle(rawValue: raw) else { return }
        IconStyle.current = style
        applyIcon()
    }

    private func addGroupHeader(_ menu: NSMenu, _ title: String) {
        menu.addItem(headerItem(title))
    }

    // Two headed groups: everything Mullvad (status, split tunnel, relay
    // pickers), then everything Tailscale (status, toggle, accept-dns — a
    // Tailscale pref), then app items.
    private func build(_ menu: NSMenu) {
        addGroupHeader(menu, deviceName.map { "Mullvad - \($0)" } ?? "Mullvad")

        let mv = NSMenuItem(title: mullvadRowLabel(mullvad), action: #selector(toggleMullvad), keyEquivalent: "")
        mv.target = self
        mv.image = dotImage(nsColor(dotColor(for: mullvad.state)))
        menu.addItem(mv)

        menu.addItem(buildSplitTunnelItem())

        let model = fastCitiesMenu(store: store, currentRelay: mullvad.relay, now: Date())
        if !model.us.rows.isEmpty { menu.addItem(fastCitiesSubmenuItem(model.us, footer: model.footer)) }
        if !model.nonus.rows.isEmpty { menu.addItem(fastCitiesSubmenuItem(model.nonus, footer: model.footer)) }

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

        let iconHeader = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        let iconSub = NSMenu()
        for style in IconStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(setIconStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == IconStyle.current ? .on : .off
            iconSub.addItem(item)
        }
        iconHeader.submenu = iconSub
        menu.addItem(iconHeader)

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
    @objc private func openTailscale() {
        _ = Shell.run("/usr/bin/open", ["-a", "Tailscale"])
    }
    @objc private func toggleTailscale() {
        let action = tailscaleToggle(backend)
        DispatchQueue.global().async { [weak self] in
            switch action {
            case .up: _ = Shell.run(TS, ["up"], env: TS_ENV)
            case .down: _ = Shell.run(TS, ["down"], env: TS_ENV)
            }
            DispatchQueue.main.async { self?.poll() }
        }
    }
    // Manual override; the DNS watcher (event-driven) re-asserts its mapping on
    // the next Mullvad connect/disconnect, so this holds only until then.
    @objc private func toggleAcceptDNS() {
        let target = corpDNS ? "false" : "true"
        DispatchQueue.global().async { [weak self] in
            _ = Shell.run(TS, ["set", "--accept-dns=\(target)"], env: TS_ENV)
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

    @objc private func toggleLogin() { LoginItem.toggle() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
