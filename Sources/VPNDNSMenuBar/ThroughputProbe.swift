// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import StatusItemKit
import VPNDNSCore

/// Measures download/upload throughput through every candidate city by
/// tunnelling through each in turn: set the relay location, wait for the
/// tunnel to land on that city, then time a download from and an upload to
/// Cloudflare's speed-test endpoints — a small probe transfer first, then one
/// sized to run about five seconds at the probed rate (capped at Cloudflare's
/// 90 MB per-request limit). Deliberately intrusive, so it runs
/// on demand from the menu or automatically only when results are older
/// than `throughputMaxAge`, Mullvad is off, and the user has been idle.
/// When it finishes (or is cancelled) it restores the original relay
/// constraint and connected/off state. All state below is main-thread-only
/// except where noted.
final class ThroughputProbe {
    enum Phase: Equatable {
        case idle
        case measuring(done: Int, total: Int, city: String)
        case restoring
    }

    private let store: LatencyStore
    private let mullvad: String
    private let isOff: () -> Bool
    private let onUpdate: () -> Void
    private let queue = DispatchQueue(label: "vpndns.throughput")
    private let cancelLock = NSLock()
    private var cancelRequested = false   // guarded by cancelLock
    private var timer: Timer?
    private(set) var phase: Phase = .idle

    static let minIdle: TimeInterval = 10 * 60
    static let downloadURL = "https://speed.cloudflare.com/__down"
    static let uploadURL = "https://speed.cloudflare.com/__up"
    static let probeBytes = 10_000_000
    // Uplinks are slower; a 10 MB probe overran the limit on the far-off
    // relays and recorded nothing.
    static let uploadProbeBytes = 2_000_000
    static let maxBytes = 90_000_000
    static let targetSeconds = 5.0

    init(store: LatencyStore, mullvad: String, isOff: @escaping () -> Bool, onUpdate: @escaping () -> Void) {
        self.store = store
        self.mullvad = mullvad
        self.isOff = isOff
        self.onUpdate = onUpdate
    }

    var isRunning: Bool { phase != .idle }

    /// Checks the automatic trigger every `interval` seconds.
    func start(interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.autoRunIfNeeded()
        }
    }

    func autoRunIfNeeded() {
        guard !isRunning else { return }
        let stale = isLatencyStale(last: store.lastThroughputMeasurement, now: Date(), maxAge: throughputMaxAge)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        guard shouldAutoMeasureThroughput(stale: stale, mullvadOff: isOff(),
                                          idleSeconds: idle, minIdle: Self.minIdle) else { return }
        startRun()
    }

    /// Manual trigger. No-op while a run is in progress.
    func startRun() {
        guard !isRunning else { return }
        cancelLock.lock(); cancelRequested = false; cancelLock.unlock()
        let relays = store.pool.us + store.pool.nonus
        guard let first = relays.first else { return }
        phase = .measuring(done: 0, total: relays.count, city: first.city)
        queue.async { [weak self] in self?.run(relays) }
    }

    /// Finish the city in progress, then restore. No-op when idle.
    func cancel() {
        guard isRunning else { return }
        cancelLock.lock(); cancelRequested = true; cancelLock.unlock()
    }

    private var cancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelRequested
    }

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { [weak self] in
            self?.phase = p
            self?.onUpdate()
        }
    }

    // MARK: - Background run

    private func run(_ relays: [CandidateRelay]) {
        let before = parseMullvadStatus(Shell.run(mullvad, ["status"]) ?? "")
        let location = parseRelayLocation(Shell.run(mullvad, ["relay", "get"]) ?? "")
        let wasConnected = before.state != .off

        defer { try? FileManager.default.removeItem(at: uploadFile) }

        var results: [CityThroughput] = []
        for (i, relay) in relays.enumerated() {
            if cancelled { break }
            setPhase(.measuring(done: i, total: relays.count, city: relay.city))
            _ = Shell.run(mullvad, ["relay", "set", "location", relay.cc, relay.cityCode])
            _ = Shell.run(mullvad, ["connect", "--wait"], timeout: 40)
            guard waitForCity(relay) else { continue }
            guard let down = measure(bytes: Self.probeBytes, upload: false)
                .flatMap({ probe in measure(bytes: sized(probe, floor: Self.probeBytes), upload: false) ?? probe })
            else { continue }
            let up = measure(bytes: Self.uploadProbeBytes, upload: true)
                .flatMap { probe in measure(bytes: sized(probe, floor: Self.uploadProbeBytes), upload: true) ?? probe } ?? 0
            results.append(CityThroughput(cityCode: relay.cityCode, downMbps: down, upMbps: up, measuredAt: Date()))
        }

        setPhase(.restoring)
        for cmd in throughputRestoreCommands(location: location, wasConnected: wasConnected) {
            _ = Shell.run(mullvad, cmd, timeout: 40)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !results.isEmpty { self.store.recordThroughput(results) }
            self.phase = .idle
            self.onUpdate()
        }
    }

    /// Poll `mullvad status` until the tunnel is up on this city (or give up).
    private func waitForCity(_ relay: CandidateRelay) -> Bool {
        for _ in 0..<25 {
            let st = parseMullvadStatus(Shell.run(mullvad, ["status"]) ?? "")
            if st.state == .connected, isCurrentCity(relay: st.relay, cc: relay.cc, cityCode: relay.cityCode) {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func sized(_ probeMbps: Double, floor: Int) -> Int {
        transferBytes(afterProbeMbps: probeMbps, targetSeconds: Self.targetSeconds,
                      minBytes: floor, maxBytes: Self.maxBytes)
    }

    /// One complete transfer of `bytes`, as Mbit/s; nil on any failure
    /// (curl's exit status is irrelevant — the write-out carries the verdict).
    /// The timeout is generous so a slow relay finishes rather than being
    /// cut off, which would make curl's rate meaningless.
    private func measure(bytes: Int, upload: Bool) -> Double? {
        var args = ["-s", "-o", "/dev/null", "--max-time", "60"]
        if upload {
            guard writeUploadFile(bytes: bytes) else { return nil }
            args += ["-w", "%{http_code} %{speed_upload}", "-X", "POST",
                     "--data-binary", "@\(uploadFile.path)", Self.uploadURL]
        } else {
            args += ["-w", "%{http_code} %{speed_download}", "\(Self.downloadURL)?bytes=\(bytes)"]
        }
        let out = Shell.run("/bin/sh", ["-c", #""$0" "$@" || true"#, "/usr/bin/curl"] + args, timeout: 70)
        return parseCurlSpeedMbps(out ?? "")
    }

    private let uploadFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("vpndns-upload-\(ProcessInfo.processInfo.processIdentifier).bin")

    private func writeUploadFile(bytes: Int) -> Bool {
        (try? Data(count: bytes).write(to: uploadFile)) != nil
    }
}
