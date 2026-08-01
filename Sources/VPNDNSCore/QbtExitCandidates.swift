import Foundation

/// One selectable exit city for the qbt tunnel, from
/// `pin-qbt-relay.sh --list` TSV (code, display, hostname, ip).
public struct QbtExitCandidate: Equatable {
    public let code: String      // "ca-mtr"
    public let display: String   // "Montreal, Canada"
    public init(code: String, display: String) {
        self.code = code
        self.display = display
    }
}

/// Parse the --list TSV into display-sorted candidates; malformed lines dropped.
public func parseQbtExitCandidates(_ tsv: String) -> [QbtExitCandidate] {
    var out: [QbtExitCandidate] = []
    for line in tsv.split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
        out.append(QbtExitCandidate(code: fields[0], display: fields[1]))
    }
    return out.sorted { $0.display < $1.display }
}

/// True when the confirmed exit hostname (e.g. "ca-mtr-wg-001") belongs to the
/// given city code ("ca-mtr"). Hyphen suffix guards against prefix collisions.
public func qbtExitIsCurrent(relay: String?, cityCode: String) -> Bool {
    guard let relay = relay else { return false }
    return relay.hasPrefix(cityCode + "-")
}
