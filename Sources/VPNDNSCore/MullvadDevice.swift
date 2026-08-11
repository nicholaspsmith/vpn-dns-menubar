import Foundation

/// Parse `mullvad account get`. The device name is the value of the
/// `Device name:` line; the account number and expiry on the other lines are
/// ignored. Returns nil when logged out — that output carries no such line — so
/// callers can fall back to an unadorned label rather than showing a blank.
public func parseMullvadDeviceName(_ raw: String) -> String? {
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let r = line.range(of: "Device name:") else { continue }
        let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    return nil
}
