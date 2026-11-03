// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
    // Shared with the iguana's accept-dns eye, so the row and the glyph
    // are visibly the same signal.
    case .cyan: return CharacterIcon.dnsCyan                                     // #3dd4ed
    }
}

/// Non-clickable group header: bold at normal menu size, drawn grey like
/// every other row you can't click. (The native macOS 14 sectionHeader style
/// was tried and rejected: its fixed small size is hard to read.)
private func headerItem(_ title: String) -> NSMenuItem {
    let item = InfoMenuItem.make(title)
    item.attributedTitle = headerTitle(title)
    return item
}

private func headerTitle(_ title: String) -> NSAttributedString {
    NSAttributedString(string: title, attributes: [
        .font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize),
        .foregroundColor: NSColor.disabledControlTextColor,
    ])
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

/// Pings candidate relays and records direct latency, only when the user
/// picks Measure ▸ Measure Latency Now. Two probe modes, chosen by `probeDecision`:
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
    private(set) var isRunning = false

    init(store: LatencyStore, isOff: @escaping () -> Bool,
         splitTunnelOn: @escaping () -> Bool, onUpdate: @escaping () -> Void) {
        self.store = store
        self.isOff = isOff
        self.splitTunnelOn = splitTunnelOn
        self.onUpdate = onUpdate
    }

    /// Whether a trustworthy probe is possible right now (main thread).
    var canMeasure: Bool { probeDecision(mullvadOff: isOff(), splitTunnelOn: splitTunnelOn()) != .skip }

    /// Main thread. The only trigger: the user's menu pick. Probes if the
    /// current state permits a trustworthy probe; no-op while one runs.
    func measureNow() {
        guard !isRunning else { return }
        switch probeDecision(mullvadOff: isOff(), splitTunnelOn: splitTunnelOn()) {
        case .skip:
            return
        case .probeDirect:
            isRunning = true
            onUpdate()
            queue.async { [weak self] in self?.runProbe(viaSplitTunnel: false) }
        case .probeViaSplitTunnel:
            isRunning = true
            onUpdate()
            queue.async { [weak self] in self?.runProbe(viaSplitTunnel: true) }
        }
    }

    private func runProbe(viaSplitTunnel: Bool) {
        defer { DispatchQueue.main.async { [weak self] in self?.isRunning = false; self?.onUpdate() } }

        if viaSplitTunnel {
            // add + verify; on any doubt, clean up and bail.
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
    private var throughput: ThroughputProbe!
    private let mullvadStateLock = NSLock()
    private var mullvadIsOff = false   // guarded by mullvadStateLock; read by probe off-main
    private let pollQueue = DispatchQueue(label: "vpndns.poll")
    private var pollInFlight = false   // main-thread only; drops overlapping polls
    /// An action finished while a poll was in flight: poll again once it lands,
    /// so the result shows without waiting for the next tick.
    private var pollAgain = false

    /// What the menu's clicks start. Each runs a CLI call off the main thread;
    /// while one is running, the rows it changes are disabled (grey), so the
    /// open menu never offers a toggle whose state it doesn't know yet.
    enum PendingAction: Hashable {
        case mullvad, tailscale, acceptDNS, splitTunnel
        case removeSplitTunnelApp(String)
    }
    /// Started, not yet reflected in a poll (main thread).
    private var actionsInFlight: Set<PendingAction> = []
    /// Finished; the next poll to start reads their result (main thread).
    private var actionsSettling: Set<PendingAction> = []

    private var preferencesModel: PreferencesModel!
    private var preferences: PreferencesPane!

    /// The rows of the open menu that change with the state, updated in place
    /// on every poll while it is open. Nil while the menu is closed.
    private final class OpenMenu {
        let header: NSMenuItem
        let mullvad: NSMenuItem
        let splitTunnel: NSMenuItem
        let cities: [(list: FastList, item: NSMenuItem)]
        let measure: NSMenuItem
        let tailscale: NSMenuItem
        let acceptDNS: NSMenuItem
        init(header: NSMenuItem, mullvad: NSMenuItem, splitTunnel: NSMenuItem,
             cities: [(list: FastList, item: NSMenuItem)], measure: NSMenuItem,
             tailscale: NSMenuItem, acceptDNS: NSMenuItem) {
            self.header = header
            self.mullvad = mullvad
            self.splitTunnel = splitTunnel
            self.cities = cities
            self.measure = measure
            self.tailscale = tailscale
            self.acceptDNS = acceptDNS
        }
    }
    private var openMenu: OpenMenu?
    private var menuIsOpen = false
    /// Polls while the menu is open. StatusItemController's own timer runs in
    /// the default run-loop mode, which a tracking menu suspends, so without
    /// this an open menu would never see a connect finish.
    private var openMenuTimer: Timer?
    private static let openMenuPollInterval: TimeInterval = 2

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
            .appendingPathComponent("VPNDNSMenuBar")
        self.store = LatencyStore(pool: pool,
                                  fileURL: support?.appendingPathComponent("latency.json"),
                                  throughputURL: support?.appendingPathComponent("throughput.json"))
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        controller = StatusItemController(
            pollInterval: 5,
            onPoll: { [weak self] in self?.poll() },
            onBuildMenu: { [weak self] menu in self?.build(menu) }
        )
        controller.onMenuWillOpen = { [weak self] in self?.menuWillOpen() }
        controller.onMenuDidClose = { [weak self] in self?.menuDidClose() }
        controller.start()
        preferencesModel = PreferencesModel(
            onIconStyle: { [weak self] in self?.applyIcon() },
            preview: { [weak self] style in self?.iconImage(style) ?? NSImage() }
        )
        preferences = PreferencesPane.vpnDNS(model: preferencesModel)
        yieldClient = YieldClient(item: controller)
        yieldClient.start()
        minuteCue = MinuteCue { [weak self] in
            guard IconStyle.current == .iguana else { return }
            self?.lickAnimation.start()
        }
        minuteCue.start()
        probe = LatencyProbe(
            store: store,
            isOff: { [weak self] in
                guard let self = self else { return false }
                self.mullvadStateLock.lock()
                defer { self.mullvadStateLock.unlock() }
                return self.mullvadIsOff
            },
            // Main-thread read: measureNow and canMeasure only run on the main thread.
            splitTunnelOn: { [weak self] in self?.splitTunnel.enabled ?? false },
            onUpdate: { [weak self] in self?.requestPoll() }
        )
        throughput = ThroughputProbe(
            store: store,
            mullvad: MULLVAD,
            isOff: { [weak self] in
                guard let self = self else { return false }
                self.mullvadStateLock.lock()
                defer { self.mullvadStateLock.unlock() }
                return self.mullvadIsOff
            },
            onUpdate: { [weak self] in self?.requestPoll() }
        )
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
        // Actions that finished before this poll began: its result shows them.
        let settling = actionsSettling
        actionsSettling = []
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
                self.lastIconColor = nsColor(dotColor(mullvad: mv.state, tailscaleRunning: be == "Running"))
                self.lastTail = be == "Running"
                self.lastTongue = mv.state == .connected
                self.lastDNS = self.corpDNS
                // The iguana colours itself by connection; only Mullvad's
                // in-between states (connecting, blocked) borrow the dot's colour.
                switch mv.state {
                case .connecting, .disconnecting, .blocked: self.lastAlert = self.lastIconColor
                default: self.lastAlert = nil
                }
                self.applyIcon()
                self.actionsInFlight.subtract(settling)
                self.refreshOpenMenu()
                if self.pollAgain {
                    self.pollAgain = false
                    self.poll()
                }
            }
        }
    }

    /// Polls now, or as soon as the poll in flight lands.
    private func requestPoll() {
        if pollInFlight { pollAgain = true } else { poll() }
    }

    /// Runs one of the menu's actions off the main thread. Its rows grey out
    /// at once and come back with the state the next poll reads.
    private func perform(_ action: PendingAction, _ work: @escaping () -> Void) {
        guard !actionsInFlight.contains(action) else { return }
        actionsInFlight.insert(action)
        refreshOpenMenu()
        DispatchQueue.global().async { [weak self] in
            work()
            DispatchQueue.main.async {
                guard let self else { return }
                self.actionsSettling.insert(action)
                self.requestPoll()
            }
        }
    }

    // MARK: - Open menu

    private func menuWillOpen() {
        menuIsOpen = true
        openMenuTimer?.invalidate()
        let timer = Timer(timeInterval: Self.openMenuPollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        openMenuTimer = timer
    }

    private func menuDidClose() {
        menuIsOpen = false
        openMenuTimer?.invalidate()
        openMenuTimer = nil
        openMenu = nil
    }

    /// Brings the open menu up to date: the header, the three status rows,
    /// and each submenu whose contents changed. A submenu with the same rows
    /// keeps its items (only ticks and greying change), so the row under the
    /// pointer is never swapped out from under it.
    private func refreshOpenMenu() {
        guard menuIsOpen, let open = openMenu else { return }
        open.header.attributedTitle = headerTitle(mullvadHeaderTitle)
        updateStatusRow(open.mullvad, title: mullvadRowLabel(mullvad),
                        dot: dotColor(for: mullvad.state), enabled: !actionsInFlight.contains(.mullvad))
        updateStatusRow(open.tailscale, title: tailscaleRowLabel(backend),
                        dot: tailscaleColor(backend), enabled: !actionsInFlight.contains(.tailscale))
        updateStatusRow(open.acceptDNS, title: acceptDNSLabel(corpDNS),
                        dot: acceptDNSDotColor(corpDNS), enabled: !actionsInFlight.contains(.acceptDNS))
        refreshSubmenu(open.splitTunnel, title: splitTunnelMenuTitle(splitTunnel.enabled), populate: populateSplitTunnel)
        let model = fastCitiesModel()
        for (list, item) in open.cities {
            guard let section = model.sections.first(where: { $0.list == list }) else { continue }
            refreshSubmenu(item, title: section.header) { [self] sub in
                populateCities(sub, section, footers: [model.footer, model.throughputFooter])
            }
        }
        refreshSubmenu(open.measure, title: measureTitle, populate: populateMeasure)
    }


    private func updateStatusRow(_ item: NSMenuItem, title: String, dot: DotColor, enabled: Bool) {
        let titleChanged = item.title != title
        item.title = title
        item.image = dotImage(nsColor(dot))
        item.isEnabled = enabled
        if titleChanged {
            // A new row measures the new title, so a longer one widens the menu.
            item.view = KeepOpenMenuRow(item: item)
        } else {
            item.view?.needsDisplay = true
            (item.view as? MenuItemRow)?.updateColors()
        }
    }

    private func refreshSubmenu(_ root: NSMenuItem, title: String, populate: (NSMenu) -> Void) {
        if root.title != title { root.title = title }
        guard let sub = root.submenu else { return }
        let fresh = NSMenu()
        populate(fresh)
        let next = fresh.items
        fresh.removeAllItems()
        func shape(_ i: NSMenuItem) -> String { "\(i.isSeparatorItem)|\(i.title)|\(String(describing: i.action))" }
        if sub.items.map(shape) == next.map(shape) {
            for (old, new) in zip(sub.items, next) {
                old.representedObject = new.representedObject
                guard old.state != new.state || old.isEnabled != new.isEnabled else { continue }
                old.state = new.state
                old.isEnabled = new.isEnabled
                (old.view as? MenuItemRow)?.updateColors()
                old.view?.needsDisplay = true
            }
            return
        }
        sub.removeAllItems()
        next.forEach(sub.addItem)
        KeepOpenMenu.apply(to: sub.items)
    }

    // MARK: - Icon style

    /// The dot, or the iguana that changes to the same colours. Persisted.
    enum IconStyle: String, CaseIterable {
        // Stored as "chameleon", what the mascot was before it became an
        // iguana, so an existing choice carries over.
        case iguana = "chameleon", dot
        var title: String { self == .dot ? "Dot" : "Iguana" }
        private static let key = "iconStyle"
        static var current: IconStyle {
            get { UserDefaults.standard.string(forKey: key).flatMap(IconStyle.init) ?? .iguana }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    private var lastIconColor: NSColor = NSColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1)
    private var lastTail = false
    private var lastTongue = false
    private var lastDNS = false
    private var lastAlert: NSColor? = nil
    /// Once a minute, in her turn with the other animated mascots, Iguanamous
    /// licks: tongue in, it flicks at the air; wrapped round the branch, it
    /// unwinds, reels in and wraps again. Seconds into the lick, nil at rest.
    private var minuteCue: MinuteCue!
    private var lickTime: TimeInterval?
    private lazy var lickAnimation = IconAnimation(duration: CharacterIcon.iguanaLickDuration, frame: { [weak self] t in
        self?.lickTime = t
        self?.applyIcon()
    }, completion: { [weak self] in
        self?.lickTime = nil
        self?.applyIcon()
    })

    private func applyIcon() {
        controller.setIcon(iconImage(IconStyle.current, lick: lickTime))
    }

    /// The icon in `style` as the bar shows it now (the Preferences tiles
    /// draw it too).
    private func iconImage(_ style: IconStyle, lick: TimeInterval? = nil) -> NSImage {
        switch style {
        case .iguana: return CharacterIcon.iguana(tailscale: lastTail, mullvad: lastTongue,
                                                  acceptDNS: lastDNS, alert: lastAlert, lick: lick)
        case .dot: return MeterIcon.dot(color: lastIconColor)
        }
    }

    private var mullvadHeaderTitle: String { deviceName.map { "Mullvad - \($0)" } ?? "Mullvad" }

    /// A status row: a dot, the state, and a click that toggles it, leaving
    /// the menu open. Disabled while its last toggle is still running.
    private func statusRow(_ title: String, dot: DotColor, action: Selector, pending: PendingAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = dotImage(nsColor(dot))
        item.isEnabled = !actionsInFlight.contains(pending)
        return item
    }

    private func submenuItem(_ title: String, populate: (NSMenu) -> Void) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        // Enabled state is set by hand (pending actions grey their rows), so
        // AppKit's validation must not override it.
        sub.autoenablesItems = false
        populate(sub)
        root.submenu = sub
        return root
    }

    // Two headed groups: everything Mullvad (status, split tunnel, relay
    // pickers), then everything Tailscale (status, toggle, accept-dns — a
    // Tailscale pref), then Preferences… and Quit. Every option keeps the
    // menu open; Quit and the "…" items close it.
    private func build(_ menu: NSMenu) {
        menu.autoenablesItems = false
        let header = headerItem(mullvadHeaderTitle)
        menu.addItem(header)

        let mv = statusRow(mullvadRowLabel(mullvad), dot: dotColor(for: mullvad.state),
                           action: #selector(toggleMullvad), pending: .mullvad)
        menu.addItem(mv)

        let split = submenuItem(splitTunnelMenuTitle(splitTunnel.enabled), populate: populateSplitTunnel)
        menu.addItem(split)

        let model = fastCitiesModel()
        var cities: [(list: FastList, item: NSMenuItem)] = []
        for section in visibleSections(model.sections, hidden: HiddenFastLists.current) {
            let item = submenuItem(section.header) { [self] sub in
                populateCities(sub, section, footers: [model.footer, model.throughputFooter])
            }
            menu.addItem(item)
            cities.append((section.list, item))
        }
        let measure = submenuItem(measureTitle, populate: populateMeasure)
        menu.addItem(measure)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(headerItem("Tailscale"))

        // Same shape as the Mullvad and MagicDNS rows: a dot, the state, and a
        // click that toggles it. It used to open the Tailscale app instead,
        // which left the three status rows behaving three different ways.
        let ts = statusRow(tailscaleRowLabel(backend), dot: tailscaleColor(backend),
                           action: #selector(toggleTailscale), pending: .tailscale)
        menu.addItem(ts)

        let dns = statusRow(acceptDNSLabel(corpDNS), dot: acceptDNSDotColor(corpDNS),
                            action: #selector(toggleAcceptDNS), pending: .acceptDNS)
        menu.addItem(dns)

        // Opening the app was the old row's job, so it keeps a home of its own.
        // It opens a window, so it closes the menu ("…").
        let openTS = NSMenuItem(title: "Open Tailscale App…", action: #selector(openTailscale), keyEquivalent: "")
        openTS.target = self
        menu.addItem(openTS)

        PreferencesMenu.addFooter(to: menu, appName: "VPN & DNS") { [weak self] in self?.preferences.show() }
        KeepOpenMenu.apply(to: menu.items)

        openMenu = OpenMenu(header: header, mullvad: mv, splitTunnel: split, cities: cities,
                            measure: measure, tailscale: ts, acceptDNS: dns)
    }

    // MARK: - Fastest lists show/hide

    /// Which "Fastest …" submenus the user has unticked. Persisted.
    enum HiddenFastLists {
        private static let key = "hiddenFastLists"
        static var current: Set<FastList> {
            get { Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(FastList.init)) }
            set { UserDefaults.standard.set(newValue.map { $0.rawValue }.sorted(), forKey: key) }
        }
    }

    /// Latency or throughput ordering for every list. Persisted.
    enum RankModeSetting {
        private static let key = "fastListRankMode"
        static var current: RankMode {
            get { RankMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .latency }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    // MARK: - Measure

    // "Measure ▸" — the only way latency or throughput is ever measured: a
    // start row for each, or progress (+ Cancel for throughput) while one is in
    // flight. The top-level title carries the progress too, so a run is visible
    // without opening the submenu.
    private var measureTitle: String {
        var title = "Measure"
        if case .measuring(let done, let total, _) = throughput.phase {
            title += " · throughput \(done + 1)/\(total)"
        } else if throughput.phase == .restoring {
            title += " · restoring"
        } else if probe.isRunning {
            title += " · latency"
        }
        return title
    }

    private func populateMeasure(_ sub: NSMenu) {
        if probe.isRunning {
            sub.addItem(InfoMenuItem.make("Measuring latency…"))
        } else if throughput.isRunning {
            // A throughput run is hopping relays; pings now would not be direct.
            sub.addItem(InfoMenuItem.make("Measure Latency Now"))
        } else if probe.canMeasure {
            let run = NSMenuItem(title: "Measure Latency Now", action: #selector(measureLatency), keyEquivalent: "")
            run.target = self
            sub.addItem(run)
        } else {
            // Connected with split tunnelling off: a ping would time the tunnel.
            sub.addItem(InfoMenuItem.make("Measure Latency Now"))
            sub.addItem(InfoMenuItem.make("Disconnect Mullvad or turn on Split Tunnel"))
        }
        switch throughput.phase {
        case .idle:
            if probe.isRunning {
                sub.addItem(InfoMenuItem.make("Measure Throughput Now"))
            } else {
                let run = NSMenuItem(title: "Measure Throughput Now", action: #selector(measureThroughput), keyEquivalent: "")
                run.target = self
                sub.addItem(run)
            }
        case .measuring(let done, let total, let city):
            sub.addItem(InfoMenuItem.make(throughputProgressTitle(done: done, total: total, city: city)))
            let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelThroughput), keyEquivalent: "")
            cancel.target = self
            sub.addItem(cancel)
        case .restoring:
            sub.addItem(InfoMenuItem.make("Restoring previous connection…"))
        }
    }

    @objc private func measureLatency() { probe.measureNow() }
    @objc private func measureThroughput() { throughput.startRun() }
    @objc private func cancelThroughput() { throughput.cancel() }

    // MARK: - Fastest cities

    private func fastCitiesModel() -> FastCitiesMenu {
        fastCitiesMenu(store: store, currentRelay: mullvad.relay, now: Date(), mode: RankModeSetting.current)
    }

    // One top-level item per fastest-cities section; city rows + freshness
    // footer live in its submenu so the top level stays short. Ticked: the
    // city Mullvad is on. Clicking it disconnects; clicking another moves
    // there. The rows grey out while that runs.
    private func populateCities(_ sub: NSMenu, _ section: MenuSection, footers: [String]) {
        let busy = actionsInFlight.contains(.mullvad)
        for row in section.rows {
            let item = NSMenuItem(title: row.title, action: #selector(toggleCity(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isCurrent ? .on : .off
            item.isEnabled = !busy
            item.representedObject = ["cc": row.cc, "city": row.cityCode]
            sub.addItem(item)
        }
        sub.addItem(NSMenuItem.separator())
        for footer in footers { sub.addItem(InfoMenuItem.make(footer)) }
    }

    @objc private func toggleCity(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let cc = info["cc"], let city = info["city"] else { return }
        let action = toggleAction(currentRelay: mullvad.relay, clickedCC: cc, clickedCityCode: city)
        perform(.mullvad) {
            switch action {
            case .disconnect:
                _ = Shell.run(MULLVAD, ["disconnect"])
            case .connect(let cc, let city):
                _ = Shell.run(MULLVAD, ["relay", "set", "location", cc, city])
                _ = Shell.run(MULLVAD, ["connect"])
            }
        }
    }

    // MARK: - Status row actions

    // Connect goes to Mullvad's persisted relay selection — no app-side copy
    // to go stale if the endpoint is changed in the native app.
    @objc private func toggleMullvad() {
        let action = mullvadToggle(mullvad.state)
        perform(.mullvad) {
            switch action {
            case .connect: _ = Shell.run(MULLVAD, ["connect"])
            case .disconnect: _ = Shell.run(MULLVAD, ["disconnect"])
            }
        }
    }
    @objc private func openTailscale() {
        _ = Shell.run("/usr/bin/open", ["-a", "Tailscale"])
    }
    @objc private func toggleTailscale() {
        let action = tailscaleToggle(backend)
        perform(.tailscale) {
            switch action {
            case .up: _ = Shell.run(TS, ["up"], env: TS_ENV)
            case .down: _ = Shell.run(TS, ["down"], env: TS_ENV)
            }
        }
    }
    // Manual override; the DNS watcher (event-driven) re-asserts its mapping on
    // the next Mullvad connect/disconnect, so this holds only until then.
    @objc private func toggleAcceptDNS() {
        let target = corpDNS ? "false" : "true"
        perform(.acceptDNS) {
            _ = Shell.run(TS, ["set", "--accept-dns=\(target)"], env: TS_ENV)
        }
    }

    // MARK: - Split tunnel

    private func populateSplitTunnel(_ sub: NSMenu) {
        let toggle = NSMenuItem(title: splitTunnelToggleLabel(splitTunnel.enabled), action: #selector(toggleSplitTunnel), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !actionsInFlight.contains(.splitTunnel)
        sub.addItem(toggle)
        let apps = splitTunnelDisplayApps(splitTunnel.apps)
        if !apps.isEmpty {
            sub.addItem(NSMenuItem.separator())
            sub.addItem(headerItem("Excluded from VPN — click to remove"))
            for path in apps {
                let item = NSMenuItem(title: splitTunnelAppDisplayName(path), action: #selector(removeSplitTunnelApp(_:)), keyEquivalent: "")
                item.target = self
                item.state = .on
                item.isEnabled = !actionsInFlight.contains(.removeSplitTunnelApp(path))
                item.representedObject = path
                item.toolTip = path
                sub.addItem(item)
            }
        }
        sub.addItem(NSMenuItem.separator())
        let add = NSMenuItem(title: "Add App…", action: #selector(addSplitTunnelApp), keyEquivalent: "")
        add.target = self
        sub.addItem(add)
    }

    @objc private func toggleSplitTunnel() {
        let target = splitTunnel.enabled ? "off" : "on"
        perform(.splitTunnel) {
            _ = Shell.run(MULLVAD, ["split-tunnel", "set", target])
        }
    }

    @objc private func removeSplitTunnelApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        perform(.removeSplitTunnelApp(path)) {
            _ = Shell.run(MULLVAD, ["split-tunnel", "app", "remove", path])
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

}

// Handle `--login on|off|status` and exit before any UI exists. Start at Login is
// SMAppService.mainApp, which can only register the calling process's own bundle,
// so this is the only way an installer or script can turn it on.
LoginCLI.runIfRequested()

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
