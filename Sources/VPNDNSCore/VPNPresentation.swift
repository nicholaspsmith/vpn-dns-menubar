// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

public enum DotColor: Equatable { case green, orange, red, grey, blue, cyan }

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

/// One shape for every status row: a name, whatever detail that row has, and
/// the state as the last word.
///
///     Connection — us-bos-wg-001 · ON
///     MagicDNS — accept-dns · OFF
///
/// Each row also carries a coloured dot and toggles what it describes when
/// clicked, so the three of them can be read and used the same way. Rows sit
/// under "Mullvad"/"Tailscale" group headers, so the name is the thing itself
/// rather than the product.
public func statusRowLabel(name: String, detail: String?, state: String) -> String {
    guard let detail, !detail.isEmpty else { return "\(name) · \(state)" }
    return "\(name) — \(detail) · \(state)"
}

/// Mullvad's in-between states say what they are rather than being forced into
/// ON/OFF: "connecting" and "blocked" are exactly the moments worth a glance.
private func stateWord(_ state: MullvadState) -> String {
    switch state {
    case .connected: return "ON"
    case .off: return "OFF"
    case .connecting: return "CONNECTING"
    case .disconnecting: return "DISCONNECTING"
    case .blocked: return "BLOCKED"
    }
}

public func mullvadRowLabel(_ s: MullvadStatus) -> String {
    // Connected: the relay is the useful detail. Otherwise the location, which
    // is where it would connect back to.
    let detail = s.state == .connected ? (s.relay ?? s.location) : s.location
    return statusRowLabel(name: "Connection", detail: detail, state: stateWord(s.state))
}

public func acceptDNSLabel(_ on: Bool) -> String {
    statusRowLabel(name: "MagicDNS", detail: "accept-dns", state: on ? "ON" : "OFF")
}

/// Status-dot color for the accept-dns menu row — the same cyan the
/// chameleon's eye takes, so the row and the glyph say the same thing. Green
/// was indistinguishable from the body whenever either VPN was up.
public func acceptDNSDotColor(_ on: Bool) -> DotColor {
    on ? .cyan : .grey
}

public func tailscaleRowLabel(_ backend: String) -> String {
    // Anything that is neither Running nor Stopped is the detail: the row then
    // explains why it is off instead of only saying that it is.
    let detail: String?
    switch backend {
    case "Running", "Stopped", "": detail = nil
    case "NeedsLogin": detail = "needs login"
    default: detail = backend.lowercased()
    }
    return statusRowLabel(name: "Connection", detail: detail, state: backend == "Running" ? "ON" : "OFF")
}

public func tailscaleColor(_ backend: String) -> DotColor {
    switch backend {
    case "Running": return .green
    case "NeedsLogin", "Starting": return .orange
    default: return .grey
    }
}

public enum MullvadToggle: Equatable { case connect, disconnect }

/// Toggle target for Mullvad: connect when off, disconnect from any live or
/// in-flight state. `mullvad connect` uses the daemon's own persisted relay
/// selection (set by the fast-city picks or the native app), so the last
/// chosen endpoint is honored without the menu app tracking a copy.
public func mullvadToggle(_ state: MullvadState) -> MullvadToggle {
    state == .off ? .connect : .disconnect
}

public enum TailscaleToggle: Equatable { case up, down }

/// Toggle target for Tailscale: bring it down if it's Running, else bring it up.
public func tailscaleToggle(_ backend: String) -> TailscaleToggle {
    backend == "Running" ? .down : .up
}

