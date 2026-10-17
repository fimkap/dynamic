import XCTest
import NIO
@testable import dynamic

final class RetriesTests: XCTestCase {
    /// The future's result so far. On an `EmbeddedEventLoop` callbacks run synchronously,
    /// and time only moves when the test advances it.
    private func outcome<T>(of future: EventLoopFuture<T>) -> Result<T, Error>? {
        var outcome: Result<T, Error>?
        future.whenComplete { outcome = $0 }
        return outcome
    }

    private func isTimeout<T>(_ outcome: Result<T, Error>?) -> Bool {
        guard case .failure(let error) = outcome, case RequestError.timedOut = error else {
            return false
        }
        return true
    }

    func testAnswerBeforeTheTimeoutPassesThrough() throws {
        let loop = EmbeddedEventLoop()
        let request = loop.makePromise(of: Int.self)
        let result = withTimeout(request.futureResult, .seconds(5))
        loop.advanceTime(by: .milliseconds(4900))
        request.succeed(42)
        loop.advanceTime(by: .seconds(10))  // the cancelled timer must not fire
        XCTAssertEqual(try outcome(of: result)?.get(), 42)
    }

    func testNoAnswerTimesOut() {
        let loop = EmbeddedEventLoop()
        let request = loop.makePromise(of: Int.self)
        let result = withTimeout(request.futureResult, .seconds(5))
        loop.advanceTime(by: .milliseconds(4999))
        XCTAssertNil(outcome(of: result))
        loop.advanceTime(by: .milliseconds(1))
        XCTAssertTrue(isTimeout(outcome(of: result)))
        request.succeed(1)  // a request must be completed before it's released
    }

    func testAnswerAfterTheTimeoutIsIgnored() {
        let loop = EmbeddedEventLoop()
        let request = loop.makePromise(of: Int.self)
        let result = withTimeout(request.futureResult, .seconds(5))
        loop.advanceTime(by: .seconds(5))
        request.succeed(42)
        XCTAssertTrue(isTimeout(outcome(of: result)))
    }

    func testErrorBeforeTheTimeoutPassesThrough() {
        struct Refused: Error {}
        let loop = EmbeddedEventLoop()
        let request = loop.makePromise(of: Int.self)
        let result = withTimeout(request.futureResult, .seconds(5))
        request.fail(Refused())
        guard case .failure(let error) = outcome(of: result) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(error is Refused)
    }

    func testRetryDelayStaysUnderAGrowingCeiling() {
        for attempt in 1...8 {
            let ceiling = min(RETRY_BASE_DELAY_MS << (attempt - 1), RETRY_MAX_DELAY_MS)
            for _ in 0..<200 {
                let delay = retryDelay(after: attempt).nanoseconds / 1_000_000
                XCTAssertTrue((0...ceiling).contains(delay), "attempt \(attempt): \(delay) ms")
            }
        }
    }
}
