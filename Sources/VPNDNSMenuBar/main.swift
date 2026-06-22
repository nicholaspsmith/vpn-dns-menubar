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
