import Foundation

/// One qualifying city: a representative relay IP (for probing) and a seed
/// latency (used until a live direct measurement replaces it).
public struct CandidateRelay: Codable, Equatable {
    public let city: String       // "Washington DC"
    public let cc: String         // "us"
    public let cityCode: String   // "was"
    public let ip: String         // representative relay IPv4
    public let seedMs: Double     // seed latency in ms

    public init(city: String, cc: String, cityCode: String, ip: String, seedMs: Double) {
        self.city = city
        self.cc = cc
        self.cityCode = cityCode
        self.ip = ip
        self.seedMs = seedMs
    }
}

/// The full candidate pool, split into US and non-US sections.
public struct CandidatePool: Codable, Equatable {
    public let generated: String
    public let us: [CandidateRelay]
    public let nonus: [CandidateRelay]

    public init(generated: String, us: [CandidateRelay], nonus: [CandidateRelay]) {
        self.generated = generated
        self.us = us
        self.nonus = nonus
    }
}

public func loadCandidates(from url: URL) throws -> CandidatePool {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CandidatePool.self, from: data)
}
