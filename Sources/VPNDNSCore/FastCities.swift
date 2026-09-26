// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// City code (2nd dash-segment) of a Mullvad relay hostname, e.g.
/// "us-was-wg-002" -> "was". Returns nil for nil/malformed input.
public func currentCityCode(fromRelay relay: String?) -> String? {
    guard let relay = relay else { return nil }
    let parts = relay.split(separator: "-")
    guard parts.count >= 2 else { return nil }
    return String(parts[1])
}

/// True when `relay` is in the given country + city, e.g.
/// isCurrentCity("us-was-wg-002", cc: "us", cityCode: "was") == true.
public func isCurrentCity(relay: String?, cc: String, cityCode: String) -> Bool {
    guard let relay = relay else { return false }
    let parts = relay.split(separator: "-")
    return parts.count >= 2 && String(parts[0]) == cc && String(parts[1]) == cityCode
}

public enum ToggleAction: Equatable {
    case connect(cc: String, cityCode: String)
    case disconnect
}

/// Clicking a city toggles: disconnect if already connected to it, else connect.
public func toggleAction(currentRelay: String?, clickedCC: String, clickedCityCode: String) -> ToggleAction {
    if isCurrentCity(relay: currentRelay, cc: clickedCC, cityCode: clickedCityCode) {
        return .disconnect
    }
    return .connect(cc: clickedCC, cityCode: clickedCityCode)
}

public struct MenuRow: Equatable {
    public let title: String
    public let cc: String
    public let cityCode: String
    public let isCurrent: Bool
    public init(title: String, cc: String, cityCode: String, isCurrent: Bool) {
        self.title = title
        self.cc = cc
        self.cityCode = cityCode
        self.isCurrent = isCurrent
    }
}

public struct MenuSection: Equatable {
    public let list: FastList
    public let rows: [MenuRow]
    public var header: String { list.header }
    public init(list: FastList, rows: [MenuRow]) {
        self.list = list
        self.rows = rows
    }
}

public struct FastCitiesMenu: Equatable {
    /// One section per `FastList`, in `FastList.allCases` order, empty ones dropped.
    public let sections: [MenuSection]
    public let footer: String
    public let throughputFooter: String
    public init(sections: [MenuSection], footer: String, throughputFooter: String) {
        self.sections = sections
        self.footer = footer
        self.throughputFooter = throughputFooter
    }
}

/// The sections the user has not unticked in the "Fastest Lists" menu.
public func visibleSections(_ sections: [MenuSection], hidden: Set<FastList>) -> [MenuSection] {
    sections.filter { !hidden.contains($0.list) }
}

private func agoText(_ last: Date, now: Date) -> String {
    let secs = Int(now.timeIntervalSince(last))
    if secs < 90 { return "just now" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    if secs < 86400 { return "\(secs / 3600)h ago" }
    return "\(secs / 86400)d ago"
}

/// Human freshness line for the footer.
public func freshnessText(_ last: Date?, now: Date) -> String {
    guard let last = last else { return "measured: seed values" }
    return "measured \(agoText(last, now: now)) (direct)"
}

/// Second footer line: when throughput was last measured.
public func throughputFreshnessText(_ last: Date?, now: Date) -> String {
    guard let last = last else { return "throughput: not measured" }
    return "throughput measured \(agoText(last, now: now))"
}

/// Row text: latency mode shows the effective latency; throughput mode shows
/// down/up Mbps, or the latency tagged "not tested" for a city never measured.
public func cityRowTitle(_ relay: CandidateRelay, store: LatencyStore, mode: RankMode) -> String {
    let ms = Int(store.ms(for: relay).rounded())
    switch mode {
    case .latency:
        return "\(relay.city) — \(ms) ms"
    case .throughput:
        guard let tp = store.throughput(for: relay) else { return "\(relay.city) — \(ms) ms · not tested" }
        return "\(relay.city) — ↓ \(Int(tp.downMbps.rounded())) ↑ \(Int(tp.upMbps.rounded())) Mbps"
    }
}

/// Build one menu section per list (top-N cities each, empty lists dropped)
/// plus the freshness footer.
public func fastCitiesMenu(store: LatencyStore, currentRelay: String?, now: Date,
                           mode: RankMode = .latency, topN: Int = 5) -> FastCitiesMenu {
    func section(_ list: FastList) -> MenuSection {
        let rows = store.topCities(list: list, n: topN, mode: mode).map { relay -> MenuRow in
            return MenuRow(
                title: cityRowTitle(relay, store: store, mode: mode),
                cc: relay.cc,
                cityCode: relay.cityCode,
                isCurrent: isCurrentCity(relay: currentRelay, cc: relay.cc, cityCode: relay.cityCode)
            )
        }
        return MenuSection(list: list, rows: rows)
    }
    return FastCitiesMenu(
        sections: FastList.allCases.map(section).filter { !$0.rows.isEmpty },
        footer: freshnessText(store.lastDirectMeasurement, now: now),
        throughputFooter: throughputFreshnessText(store.lastThroughputMeasurement, now: now)
    )
}
