// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// The two things Preferences ▸ Measure can run.
public enum MeasureKind: Equatable {
    case latency, throughput
}

/// A measurement in flight, as the Preferences window and the menu show it.
public enum MeasureActivity: Equatable {
    /// `done` of `total` relays pinged.
    case latency(done: Int, total: Int, cancelling: Bool)
    /// `done` cities finished; `city` is being measured since `cityStarted`.
    case throughput(done: Int, total: Int, city: String, cityStarted: Date, cancelling: Bool)
    /// A throughput run putting the relay and connection back as it found them.
    case restoring

    public var kind: MeasureKind {
        switch self {
        case .latency: return .latency
        case .throughput, .restoring: return .throughput
        }
    }

    /// Whether Cancel still has something to stop.
    public var canCancel: Bool {
        switch self {
        case .latency(_, _, let cancelling), .throughput(_, _, _, _, let cancelling): return !cancelling
        case .restoring: return false
        }
    }
}

/// What the progress bar shows: how full it is and the line above it.
/// A nil `fraction` is a bar with no estimate (cancelling, restoring).
public struct MeasureProgress: Equatable {
    public let fraction: Double?
    public let label: String
    public init(fraction: Double?, label: String) {
        self.fraction = fraction
        self.label = label
    }
}

/// How long one city of a throughput run usually takes (15–20 s: connect,
/// then four transfers). Only paces the bar between cities.
public let throughputCitySeconds: TimeInterval = 18

/// The most of a city's share the estimate may fill before the city is done,
/// so a slow city never looks finished.
private let cityShareCap = 0.95

/// Progress of `activity` at `now`. Latency counts the relays pinged.
/// Throughput counts the cities finished and creeps through the current
/// one by `throughputCitySeconds`, since a city reports nothing until it ends.
public func measureProgress(_ activity: MeasureActivity, now: Date) -> MeasureProgress {
    switch activity {
    case .latency(_, _, true):
        return MeasureProgress(fraction: nil, label: "Cancelling latency measurement…")
    case .throughput(_, _, _, _, true):
        return MeasureProgress(fraction: nil, label: "Cancelling throughput run…")
    case .restoring:
        return MeasureProgress(fraction: nil, label: "Restoring previous connection…")
    case .latency(let done, let total, _):
        return MeasureProgress(fraction: total > 0 ? min(1, Double(done) / Double(total)) : 0,
                               label: "Measuring latency… \(done)/\(total)")
    case .throughput(let done, let total, let city, let cityStarted, _):
        let elapsed = max(0, now.timeIntervalSince(cityStarted))
        let cityShare = min(cityShareCap, elapsed / throughputCitySeconds)
        return MeasureProgress(fraction: total > 0 ? min(1, (Double(done) + cityShare) / Double(total)) : 0,
                               label: throughputProgressTitle(done: done, total: total, city: city))
    }
}

/// Everything Preferences ▸ Measure draws from: the run in flight (nil when
/// idle), whether pings would go out directly right now, and when each
/// measurement last finished.
public struct MeasureState: Equatable {
    public var activity: MeasureActivity?
    public var canMeasureLatency: Bool
    public var lastLatency: Date?
    public var lastThroughput: Date?

    public init(activity: MeasureActivity? = nil, canMeasureLatency: Bool = true,
                lastLatency: Date? = nil, lastThroughput: Date? = nil) {
        self.activity = activity
        self.canMeasureLatency = canMeasureLatency
        self.lastLatency = lastLatency
        self.lastThroughput = lastThroughput
    }

    /// Whether `kind`'s button is live: one measurement at a time, and
    /// latency only while a ping would time the relay, not the tunnel.
    public func canStart(_ kind: MeasureKind) -> Bool {
        guard activity == nil else { return false }
        return kind == .throughput || canMeasureLatency
    }

    /// The grey line under `kind`'s name: when it last ran, or why latency
    /// can't run now. (During a run Mullvad is connected because of the run,
    /// so the reason is left out.)
    public func detail(_ kind: MeasureKind, now: Date) -> String {
        switch kind {
        case .latency:
            if activity == nil, !canMeasureLatency { return "Disconnect Mullvad or turn on Split Tunnel" }
            return lastMeasuredText(lastLatency, now: now)
        case .throughput:
            return lastMeasuredText(lastThroughput, now: now)
        }
    }
}

/// The line under a Measure row in Preferences: when it last ran.
public func lastMeasuredText(_ last: Date?, now: Date) -> String {
    guard let last else { return "Not measured yet" }
    return "Last measured \(agoText(last, now: now))"
}
