import XCTest
@testable import dynamic

final class TallyTests: XCTestCase {
    func testCompleteOnlyWhenNothingFailedOrWasSkipped() {
        let tally = Tally()
        tally.written()
        tally.retried()
        XCTAssertTrue(tally.isComplete)
        tally.skipped()
        XCTAssertFalse(tally.isComplete)
    }

    func testSummaryCountsAndListsFailures() {
        struct Refused: Error, CustomStringConvertible {
            var description: String { return "refused" }
        }
        let tally = Tally()
        for _ in 0..<3 {
            tally.written()
        }
        tally.retried()
        tally.failed(7, Refused())
        let summary = tally.summary(seconds: 1.5)
        XCTAssertTrue(summary.hasPrefix("Wrote 3 rows in 1.5 s (2 rows/s). Retries: 1. Failed rows: 1. Skipped as invalid: 0."), summary)
        XCTAssertTrue(summary.contains("product_id 7: refused"), summary)
        XCTAssertTrue(summary.contains("running the file again is safe"), summary)
        XCTAssertFalse(tally.isComplete)
    }

    func testCountsFromManyThreads() {
        let tally = Tally()
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            tally.written()
        }
        XCTAssertTrue(tally.summary(seconds: 1).hasPrefix("Wrote 10000 rows"))
    }
}
