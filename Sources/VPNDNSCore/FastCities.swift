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
