// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// How the "Fastest …" lists are ordered. Persisted by the app as rawValue.
public enum RankMode: String, CaseIterable, Codable {
    case latency, throughput

    public var menuTitle: String {
        switch self {
        case .latency:    return "Rank by Latency"
        case .throughput: return "Rank by Throughput"
        }
    }
}

/// One throughput measurement for a city, taken while tunnelled through it.
public struct CityThroughput: Codable, Equatable {
    public let cityCode: String
    public let downMbps: Double
    public let upMbps: Double
    public let measuredAt: Date
    public init(cityCode: String, downMbps: Double, upMbps: Double, measuredAt: Date) {
        self.cityCode = cityCode
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.measuredAt = measuredAt
    }
}

/// Parse `curl -w '%{http_code} %{speed_download}'` (or `%{speed_upload}`)
/// output into megabits per second. Only a completed 200 counts: an
/// over-cap 403, a failed connection (code 000) and a zero rate are nil so a
/// bad run never records a result. (curl's speed fields are meaningless for a
/// transfer `--max-time` cut short, which is why runs use sized transfers
/// that finish rather than timed ones.)
public func parseCurlSpeedMbps(_ output: String) -> Double? {
    let fields = output.split(whereSeparator: { $0 == " " || $0 == "\n" })
    guard fields.count == 2, fields[0] == "200",
          let bytesPerSec = Double(fields[1]), bytesPerSec > 0 else { return nil }
    return bytesPerSec * 8 / 1_000_000
}

/// Size of the main transfer after a small probe: enough bytes for about
/// `targetSeconds` at the probed rate, clamped to [minBytes, maxBytes]
/// (the ceiling is Cloudflare's per-request cap).
public func transferBytes(afterProbeMbps mbps: Double, targetSeconds: Double,
                          minBytes: Int, maxBytes: Int) -> Int {
    let wanted = mbps * 1_000_000 / 8 * targetSeconds
    return min(maxBytes, max(minBytes, Int(wanted)))
}

/// The automatic run fires at most once per this interval, counted from the
/// last run that *started* (automatic or manual) — not the last one that
/// recorded a result, so a run where every city fails (an expired account,
/// say) still waits a full day before trying again.
public let throughputAutoInterval: TimeInterval = 86400

/// The automatic run is intrusive (it tunnels through every candidate), so it
/// needs all three: no run started within `throughputAutoInterval`, Mullvad
/// already off, and the user away from the keyboard for at least `minIdle`
/// seconds.
public func shouldAutoMeasureThroughput(lastRun: Date?, now: Date, mullvadOff: Bool,
                                        idleSeconds: TimeInterval, minIdle: TimeInterval) -> Bool {
    isLatencyStale(last: lastRun, now: now, maxAge: throughputAutoInterval)
        && mullvadOff && idleSeconds >= minIdle
}

/// Menu row shown while a run is in progress. `done` is the number of cities
/// already finished; `city` is the one being measured now.
public func throughputProgressTitle(done: Int, total: Int, city: String) -> String {
    "Measuring throughput… \(done + 1)/\(total) \(city)"
}

/// The relay-location constraint as `mullvad relay get` prints it, kept so a
/// throughput run can put it back exactly when it finishes.
public enum RelayLocation: Equatable {
    case any
    case country(cc: String)
    case city(cc: String, city: String)
    case hostname(cc: String, city: String, host: String)
    case customList(name: String)

    /// Arguments to the `mullvad` CLI that re-apply this constraint.
    public var restoreArgs: [String] {
        switch self {
        case .any:                          return ["relay", "set", "location", "any"]
        case .country(let cc):              return ["relay", "set", "location", cc]
        case .city(let cc, let city):       return ["relay", "set", "location", cc, city]
        case .hostname(let cc, let city, let host):
            return ["relay", "set", "location", cc, city, host]
        case .customList(let name):         return ["relay", "set", "custom-list", name]
        }
    }
}

/// Parse the `Location:` line of `mullvad relay get`. The CLI prints one of
/// `any`, `country <cc>`, `city <city>, <cc>`, `city <city>, <cc>, hostname
/// <host>`, or a custom list's bare name. nil when the line is missing.
public func parseRelayLocation(_ output: String) -> RelayLocation? {
    for line in output.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("Location:") else { continue }
        let value = t.dropFirst("Location:".count).trimmingCharacters(in: .whitespaces)
        if value == "any" { return .any }
        if value.hasPrefix("country ") {
            return .country(cc: String(value.dropFirst("country ".count)))
        }
        if value.hasPrefix("city ") {
            let parts = value.dropFirst("city ".count)
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { return nil }
            if parts.count >= 3, parts[2].hasPrefix("hostname ") {
                return .hostname(cc: parts[1], city: parts[0],
                                 host: String(parts[2].dropFirst("hostname ".count)))
            }
            return .city(cc: parts[1], city: parts[0])
        }
        return value.isEmpty ? nil : .customList(name: value)
    }
    return nil
}

/// The `mullvad` invocations that put things back after a run: the original
/// location constraint (when it could be parsed), then the original
/// connected/off state.
public func throughputRestoreCommands(location: RelayLocation?, wasConnected: Bool) -> [[String]] {
    var cmds: [[String]] = []
    if let location { cmds.append(location.restoreArgs) }
    cmds.append(wasConnected ? ["connect", "--wait"] : ["disconnect"])
    return cmds
}
