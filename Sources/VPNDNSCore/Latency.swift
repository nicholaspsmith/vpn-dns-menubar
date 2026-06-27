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

public enum Region: String, Codable { case us, nonus }

/// A latency measurement for one city. `direct` is true when measured with the
/// Mullvad tunnel down (the only trustworthy condition).
public struct CityLatency: Codable, Equatable {
    public let cityCode: String
    public let ms: Double
    public let measuredAt: Date
    public let direct: Bool
    public init(cityCode: String, ms: Double, measuredAt: Date, direct: Bool) {
        self.cityCode = cityCode
        self.ms = ms
        self.measuredAt = measuredAt
        self.direct = direct
    }
}

/// Holds the candidate pool plus the latest per-city measurements, ranks cities
/// by effective latency (measured if available, else seed), and persists
/// measurements to `fileURL` (JSON) when provided.
public final class LatencyStore {
    public let pool: CandidatePool
    private var measured: [String: CityLatency]
    private let fileURL: URL?

    public init(pool: CandidatePool, fileURL: URL? = nil) {
        self.pool = pool
        self.fileURL = fileURL
        if let url = fileURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: CityLatency].self, from: data) {
            self.measured = saved
        } else {
            self.measured = [:]
        }
    }

    /// Effective latency: measured value if present, otherwise the seed.
    public func ms(for relay: CandidateRelay) -> Double {
        measured[relay.cityCode]?.ms ?? relay.seedMs
    }

    public func recordAll(_ measurements: [CityLatency]) {
        for m in measurements { measured[m.cityCode] = m }
        persist()
    }

    /// Most recent direct-measurement timestamp across all cities, if any.
    public var lastDirectMeasurement: Date? {
        measured.values.filter { $0.direct }.map { $0.measuredAt }.max()
    }

    public func topCities(region: Region, n: Int) -> [CandidateRelay] {
        let list = (region == .us) ? pool.us : pool.nonus
        let sorted = list.sorted { ms(for: $0) < ms(for: $1) }
        return Array(sorted.prefix(n))
    }

    private func persist() {
        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder().encode(measured) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
