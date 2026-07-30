import Foundation

/// Non-secret metadata about the dedicated qbt tunnel device, read from
/// /etc/wireguard-qbt/device.json (world-readable; the private key is not in it).
public struct QbtDevice: Equatable {
    public let address: String
    public init(address: String) { self.address = address }
}

/// Extract "ipv4_address" from device.json. Same quote-token technique as
/// parseTailscaleBackend: works for single- or multi-line JSON without a decoder.
public func parseQbtDevice(_ json: String) -> QbtDevice? {
    for line in json.split(separator: "\n") {
        guard line.contains("\"ipv4_address\"") else { continue }
        let parts = line.split(separator: "\"")
        if let idx = parts.firstIndex(of: "ipv4_address"), idx + 2 < parts.count {
            return QbtDevice(address: String(parts[idx + 2]))
        }
    }
    return nil
}

/// True when `ifconfig utun100` output shows exactly this inet address.
/// Trailing space in the needle prevents "10.1.2.3" matching "10.1.2.34".
public func parseIfconfigHasAddress(_ out: String, address: String) -> Bool {
    out.contains("inet \(address) ")
}

/// True when lsof output has a LISTEN line bound to the tunnel address.
public func parseQbtListening(_ lsofOut: String, address: String) -> Bool {
    for line in lsofOut.split(separator: "\n")
    where line.contains("\(address):") && line.contains("(LISTEN)") {
        return true
    }
    return false
}

/// Exit relay hostname from https://am.i.mullvad.net/json.
public func parseExitHostname(_ amIJson: String) -> String? {
    for line in amIJson.split(separator: "\n") {
        guard line.contains("\"mullvad_exit_ip_hostname\"") else { continue }
        let parts = line.split(separator: "\"")
        if let idx = parts.firstIndex(of: "mullvad_exit_ip_hostname"), idx + 2 < parts.count {
            return String(parts[idx + 2])
        }
    }
    return nil
}

public enum QbtTunnelState: Equatable {
    case notInstalled          // no device.json — feature absent; hide the rows
    case tunnelDown            // utun100 missing, wrong address, or dead handshake
    case qbtNotRunning         // tunnel live, qBittorrent not running
    case qbtNotBound           // tunnel live, qbt running but no listener on the tunnel address
    case active(relay: String?)
}

public func deriveQbtState(installed: Bool, ifaceUp: Bool, alive: Bool,
                           qbtRunning: Bool, qbtListening: Bool, relay: String?) -> QbtTunnelState {
    if !installed { return .notInstalled }
    if !(ifaceUp && alive) { return .tunnelDown }
    if !qbtRunning { return .qbtNotRunning }
    if !qbtListening { return .qbtNotBound }
    return .active(relay: relay)
}

public func qbtRowLabel(_ s: QbtTunnelState) -> String {
    switch s {
    case .notInstalled: return "qBittorrent: not installed"
    case .tunnelDown: return "qBittorrent: ○ tunnel down — torrents stalled (safe)"
    case .qbtNotRunning: return "qBittorrent: ● tunnel up · qbt not running"
    case .qbtNotBound: return "qBittorrent: ◐ tunnel up · qbt not bound"
    case .active(let relay):
        if let relay = relay { return "qBittorrent: ● via \(relay)" }
        return "qBittorrent: ● tunneled"
    }
}
