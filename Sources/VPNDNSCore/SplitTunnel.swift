import Foundation

/// State of `mullvad split-tunnel get`: whether the policy is on, and the
/// excluded application paths (in the CLI's order).
public struct SplitTunnelStatus: Equatable {
    public let enabled: Bool
    public let apps: [String]
    public init(enabled: Bool, apps: [String]) {
        self.enabled = enabled
        self.apps = apps
    }
}

/// Parse `mullvad split-tunnel get` output:
///     Split tunneling state: on
///     Excluded applications:
///     /path/one
///     /path/two
public func parseSplitTunnel(_ raw: String) -> SplitTunnelStatus {
    var enabled = false
    var apps: [String] = []
    for line in raw.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Split tunneling state:") {
            enabled = t.hasSuffix(" on")
        } else if t.hasPrefix("/") {
            apps.append(t)
        }
    }
    return SplitTunnelStatus(enabled: enabled, apps: apps)
}

/// Human name for an excluded path. Bundle binaries show the .app name
/// ("/Applications/Arc.app/Contents/MacOS/Arc" -> "Arc"); versioned bare
/// binaries show "<tool> (<version>)" (".../claude/versions/2.1.220" ->
/// "claude (2.1.220)"); anything else is its basename.
public func splitTunnelAppDisplayName(_ path: String) -> String {
    let parts = path.split(separator: "/").map(String.init)
    if let bundle = parts.first(where: { $0.hasSuffix(".app") }) {
        return String(bundle.dropLast(4))
    }
    if let last = parts.last {
        let versionish = !last.isEmpty && last.allSatisfy { $0.isNumber || $0 == "." }
        if versionish, parts.count >= 3 {
            return "\(parts[parts.count - 3]) (\(last))"
        }
        return last
    }
    return path
}

public func splitTunnelMenuTitle(_ enabled: Bool) -> String {
    "Split Tunnel: \(enabled ? "On" : "Off")"
}

public func splitTunnelToggleLabel(_ enabled: Bool) -> String {
    enabled ? "Disable Split Tunneling" : "Enable Split Tunneling"
}
