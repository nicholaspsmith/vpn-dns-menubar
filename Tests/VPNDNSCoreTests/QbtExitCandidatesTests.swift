import XCTest
@testable import VPNDNSCore

final class QbtExitCandidatesTests: XCTestCase {
    func testParseQbtExitCandidates() {
        let tsv = """
        mx-qro\tQueretaro, Mexico\tmx-qro-wg-001\t149.88.22.129
        ca-mtr\tMontreal, Canada\tca-mtr-wg-001\t146.70.198.66
        garbage-without-tabs
        """
        let parsed = parseQbtExitCandidates(tsv)
        XCTAssertEqual(parsed, [
            QbtExitCandidate(code: "ca-mtr", display: "Montreal, Canada"),
            QbtExitCandidate(code: "mx-qro", display: "Queretaro, Mexico"),
        ])   // sorted by display; malformed line dropped
        XCTAssertEqual(parseQbtExitCandidates(""), [])
    }

    func testQbtExitIsCurrent() {
        XCTAssertTrue(qbtExitIsCurrent(relay: "ca-mtr-wg-001", cityCode: "ca-mtr"))
        XCTAssertFalse(qbtExitIsCurrent(relay: "ca-mtr-wg-001", cityCode: "ca-tor"))
        XCTAssertFalse(qbtExitIsCurrent(relay: "ca-mtrx-wg-001", cityCode: "ca-mtr"))
        XCTAssertFalse(qbtExitIsCurrent(relay: nil, cityCode: "ca-mtr"))
    }
}
