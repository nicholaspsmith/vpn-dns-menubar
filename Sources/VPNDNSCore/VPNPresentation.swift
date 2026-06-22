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
