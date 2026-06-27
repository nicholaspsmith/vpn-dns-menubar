import Foundation

/// Parse the **min** round-trip time (ms) from `/sbin/ping` summary output.
/// Looks for the `round-trip min/avg/max/stddev = a/b/c/d ms` line (or Linux
/// `rtt ...`) and returns `a`. Returns nil when no summary line is present.
public func parsePingMinRTT(_ output: String) -> Double? {
    for line in output.split(separator: "\n") {
        guard line.contains("round-trip") || line.contains("rtt") else { continue }
        guard let eq = line.range(of: "= ") else { continue }
        let after = line[eq.upperBound...]
        guard let firstField = after.split(separator: "/").first else { continue }
        let num = firstField.trimmingCharacters(in: .whitespaces)
        if let v = Double(num) { return v }
    }
    return nil
}
