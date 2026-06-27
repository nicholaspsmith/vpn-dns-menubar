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
    public let header: String
    public let rows: [MenuRow]
    public init(header: String, rows: [MenuRow]) {
        self.header = header
        self.rows = rows
    }
}

public struct FastCitiesMenu: Equatable {
    public let us: MenuSection
    public let nonus: MenuSection
    public let footer: String
    public init(us: MenuSection, nonus: MenuSection, footer: String) {
        self.us = us
        self.nonus = nonus
        self.footer = footer
    }
}

/// Human freshness line for the footer.
public func freshnessText(_ last: Date?, now: Date) -> String {
    guard let last = last else { return "measured: seed values" }
    let secs = Int(now.timeIntervalSince(last))
    let ago: String
    if secs < 90 { ago = "just now" }
    else if secs < 3600 { ago = "\(secs / 60)m ago" }
    else if secs < 86400 { ago = "\(secs / 3600)h ago" }
    else { ago = "\(secs / 86400)d ago" }
    return "measured \(ago) (direct)"
}

/// Build the two menu sections (top-N cities each) plus the freshness footer.
public func fastCitiesMenu(store: LatencyStore, currentRelay: String?, now: Date,
                           topN: Int = 3) -> FastCitiesMenu {
    func section(_ region: Region, _ header: String) -> MenuSection {
        let rows = store.topCities(region: region, n: topN).map { relay -> MenuRow in
            let ms = Int(store.ms(for: relay).rounded())
            return MenuRow(
                title: "\(relay.city) — \(ms) ms",
                cc: relay.cc,
                cityCode: relay.cityCode,
                isCurrent: isCurrentCity(relay: currentRelay, cc: relay.cc, cityCode: relay.cityCode)
            )
        }
        return MenuSection(header: header, rows: rows)
    }
    return FastCitiesMenu(
        us: section(.us, "Fastest US (No-ID)"),
        nonus: section(.nonus, "Fastest Non-US (No-ID · torrent-safe)"),
        footer: freshnessText(store.lastDirectMeasurement, now: now)
    )
}
