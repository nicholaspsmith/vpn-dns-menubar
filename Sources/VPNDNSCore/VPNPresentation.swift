import Foundation

public enum DotColor: Equatable { case green, orange, red, grey, blue }

public func dotColor(for state: MullvadState) -> DotColor {
    switch state {
    case .connected: return .green
    case .connecting, .disconnecting: return .orange
    case .blocked: return .red
    case .off: return .grey
    }
}

/// The menu-bar dot color from both states. Mullvad states win (green/orange/red);
/// blue shows when Mullvad is off but Tailscale is running (the active path);
/// grey when both are off. Mullvad-connected makes the tailnet unreachable, so the
/// two are effectively mutually exclusive — blue simply replaces grey.
public func dotColor(mullvad state: MullvadState, tailscaleRunning: Bool) -> DotColor {
    if state == .off && tailscaleRunning { return .blue }
    return dotColor(for: state)
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

public enum TailscaleToggle: Equatable { case up, down }

/// Toggle target for Tailscale: bring it down if it's Running, else bring it up.
public func tailscaleToggle(_ backend: String) -> TailscaleToggle {
    backend == "Running" ? .down : .up
}

public func tailscaleToggleLabel(_ backend: String) -> String {
    backend == "Running" ? "Disconnect Tailscale" : "Connect Tailscale"
}
