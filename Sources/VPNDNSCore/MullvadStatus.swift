import Foundation

public enum MullvadState: String {
    case connected, connecting, disconnecting, blocked, off
}

public struct MullvadStatus: Equatable {
    public let state: MullvadState
    public let relay: String?
    public let location: String?

    public init(state: MullvadState, relay: String?, location: String?) {
        self.state = state
        self.relay = relay
        self.location = location
    }
}

/// Parse `mullvad status`. State is the first word of the first line; Relay and
/// Visible location are pulled from their labelled lines if present.
public func parseMullvadStatus(_ raw: String) -> MullvadStatus {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Leading run of letters of the first line. Splitting on " " alone would glue
    // trailing punctuation onto the word (e.g. "Disconnecting..."), so take only
    // the alphabetic prefix.
    let firstWord = String(
        (lines.first?.trimmingCharacters(in: .whitespaces) ?? "")
            .prefix { $0.isLetter }
    )
    let state: MullvadState
    switch firstWord {
    case "Connected": state = .connected
    case "Connecting": state = .connecting
    case "Disconnecting": state = .disconnecting
    case "Blocked": state = .blocked
    default: state = .off
    }

    func value(after label: String) -> String? {
        for line in lines {
            if let r = line.range(of: label) {
                return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    return MullvadStatus(state: state, relay: value(after: "Relay:"), location: value(after: "Visible location:"))
}
