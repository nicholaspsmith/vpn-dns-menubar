// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import XCTest
@testable import VPNDNSCore

final class MeasureProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    private func throughput(done: Int, total: Int = 21, cancelling: Bool = false) -> MeasureActivity {
        .throughput(done: done, total: total, city: "Chicago, IL", cityStarted: start, cancelling: cancelling)
    }

    // MARK: Latency

    func testLatencyBarIsTheShareOfRelaysPinged() {
        let p = measureProgress(.latency(done: 7, total: 21, cancelling: false), now: start)
        XCTAssertEqual(p.fraction!, 7.0 / 21.0, accuracy: 0.0001)
        XCTAssertEqual(p.label, "Measuring latency… 7/21")
    }

    func testLatencyWithNoRelaysIsAnEmptyBar() {
        XCTAssertEqual(measureProgress(.latency(done: 0, total: 0, cancelling: false), now: start).fraction, 0)
    }

    // MARK: Throughput

    func testThroughputBarStartsACityAtTheCitiesAlreadyDone() {
        let p = measureProgress(throughput(done: 3), now: start)
        XCTAssertEqual(p.fraction!, 3.0 / 21.0, accuracy: 0.0001)
        XCTAssertEqual(p.label, "Measuring throughput… 4/21 Chicago, IL")
    }

    func testThroughputBarCreepsThroughACityByEstimate() {
        // Half of the estimated time for a city: half of that city's share.
        let p = measureProgress(throughput(done: 3), now: start.addingTimeInterval(throughputCitySeconds / 2))
        XCTAssertEqual(p.fraction!, 3.5 / 21.0, accuracy: 0.0001)
    }

    func testASlowCityNeverFillsItsWholeShare() {
        // The estimate ran out long ago; the bar waits short of the next city.
        let p = measureProgress(throughput(done: 3), now: start.addingTimeInterval(500))
        XCTAssertEqual(p.fraction!, 3.95 / 21.0, accuracy: 0.0001)
    }

    func testAClockBehindTheCityStartDoesNotMoveTheBarBack() {
        let p = measureProgress(throughput(done: 3), now: start.addingTimeInterval(-30))
        XCTAssertEqual(p.fraction!, 3.0 / 21.0, accuracy: 0.0001)
    }

    func testTheLastCityNeverReadsAsFinished() {
        let p = measureProgress(throughput(done: 20), now: start.addingTimeInterval(500))
        XCTAssertLessThan(p.fraction!, 1)
    }

    // MARK: Winding down

    func testCancellingHasNoEstimate() {
        let latency = measureProgress(.latency(done: 7, total: 21, cancelling: true), now: start)
        XCTAssertNil(latency.fraction)
        XCTAssertEqual(latency.label, "Cancelling latency measurement…")
        let run = measureProgress(throughput(done: 3, cancelling: true), now: start)
        XCTAssertNil(run.fraction)
        XCTAssertEqual(run.label, "Cancelling throughput run…")
    }

    func testRestoringHasNoEstimate() {
        let p = measureProgress(.restoring, now: start)
        XCTAssertNil(p.fraction)
        XCTAssertEqual(p.label, "Restoring previous connection…")
    }

    // MARK: Which row, and whether Cancel still does anything

    func testKind() {
        XCTAssertEqual(MeasureActivity.latency(done: 0, total: 21, cancelling: false).kind, .latency)
        XCTAssertEqual(throughput(done: 0).kind, .throughput)
        XCTAssertEqual(MeasureActivity.restoring.kind, .throughput)
    }

    func testCancelIsOfferedOnlyWhileMeasuring() {
        XCTAssertTrue(MeasureActivity.latency(done: 0, total: 21, cancelling: false).canCancel)
        XCTAssertTrue(throughput(done: 0).canCancel)
        XCTAssertFalse(MeasureActivity.latency(done: 0, total: 21, cancelling: true).canCancel)
        XCTAssertFalse(throughput(done: 0, cancelling: true).canCancel)
        XCTAssertFalse(MeasureActivity.restoring.canCancel)
    }

    // MARK: The Preferences rows

    func testEitherCanStartWhenNothingRuns() {
        let s = MeasureState()
        XCTAssertTrue(s.canStart(.latency))
        XCTAssertTrue(s.canStart(.throughput))
    }

    func testLatencyCannotStartWhenPingsWouldGoThroughTheTunnel() {
        let s = MeasureState(canMeasureLatency: false)
        XCTAssertFalse(s.canStart(.latency))
        XCTAssertTrue(s.canStart(.throughput))
        XCTAssertEqual(s.detail(.latency, now: start), "Disconnect Mullvad or turn on Split Tunnel")
    }

    func testOnlyOneMeasurementAtATime() {
        for activity in [MeasureActivity.latency(done: 0, total: 21, cancelling: false), throughput(done: 0), .restoring] {
            let s = MeasureState(activity: activity)
            XCTAssertFalse(s.canStart(.latency))
            XCTAssertFalse(s.canStart(.throughput))
        }
    }

    func testDetailSaysWhenEachLastRan() {
        let s = MeasureState(lastLatency: start.addingTimeInterval(-2 * 3600), lastThroughput: nil)
        XCTAssertEqual(s.detail(.latency, now: start), "Last measured 2h ago")
        XCTAssertEqual(s.detail(.throughput, now: start), "Not measured yet")
    }

    func testAThroughputRunDoesNotBlameMullvadForTheWait() {
        // The run itself has Mullvad connected; "Disconnect Mullvad" would be wrong advice.
        let s = MeasureState(activity: throughput(done: 2), canMeasureLatency: false,
                             lastLatency: start.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(s.detail(.latency, now: start), "Last measured 2h ago")
    }

    // MARK: When each was last measured

    func testLastMeasuredText() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(lastMeasuredText(nil, now: now), "Not measured yet")
        XCTAssertEqual(lastMeasuredText(now.addingTimeInterval(-30), now: now), "Last measured just now")
        XCTAssertEqual(lastMeasuredText(now.addingTimeInterval(-2 * 3600), now: now), "Last measured 2h ago")
    }
}
