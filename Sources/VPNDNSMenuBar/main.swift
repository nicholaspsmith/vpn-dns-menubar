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
    case .blue: return NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)      // #0a84ff
    }
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

final class App: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController!
    private var mullvad = MullvadStatus(state: .off, relay: nil, location: nil)
    private var backend = "Unknown"
    private var corpDNS = false
    private let store: LatencyStore
    private var probe: LatencyProbe!
    private let mullvadStateLock = NSLock()
    private var mullvadIsOff = false   // guarded by mullvadStateLock; read by probe off-main

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
            onUpdate: { }
        )
        probe.start(interval: 15 * 60)
    }

    private func poll() {
        let previous = mullvad.state
        mullvad = parseMullvadStatus(Shell.run(MULLVAD, ["status"]) ?? "")
        mullvadStateLock.lock()
        mullvadIsOff = (mullvad.state == .off)
        mullvadStateLock.unlock()
        if previous != .off && mullvad.state == .off { probe?.probeIfOff() }
        backend = parseTailscaleBackend(Shell.run(TS, ["status", "--json"]) ?? "")
        corpDNS = parseCorpDNS(Shell.run(TS, ["debug", "prefs"]) ?? "")
        controller.setIcon(MeterIcon.dot(color: nsColor(dotColor(mullvad: mullvad.state, tailscaleRunning: backend == "Running"))))
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

        let tsToggle = NSMenuItem(title: tailscaleToggleLabel(backend), action: #selector(toggleTailscale), keyEquivalent: "")
        tsToggle.target = self
        menu.addItem(tsToggle)

        menu.addItem(NSMenuItem.separator())

        let model = fastCitiesMenu(store: store, currentRelay: mullvad.relay, now: Date())
        addFastSection(menu, model.us)
        addFastSection(menu, model.nonus)
        if !model.us.rows.isEmpty || !model.nonus.rows.isEmpty {
            let foot = NSMenuItem(title: model.footer, action: nil, keyEquivalent: "")
            foot.isEnabled = false
            menu.addItem(foot)
            menu.addItem(NSMenuItem.separator())
        }

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

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

    // Open Mullvad's native popover by AX-clicking its status item (inlined from
    // assets/open-native-menu.sh). Needs Accessibility + Automation permission.
    @objc private func openMullvad() {
        _ = Shell.run("/usr/bin/osascript", ["-e",
            "tell application \"System Events\" to tell process \"Mullvad VPN\" to click menu bar item 1 of menu bar 2"])
    }
    @objc private func openTailscale() {
        _ = Shell.run("/usr/bin/open", ["-a", "Tailscale"])
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
    @objc private func toggleLogin() { LoginItem.toggle() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
