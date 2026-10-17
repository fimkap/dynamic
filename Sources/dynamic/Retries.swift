//
//  Retries.swift
//  dynamic
//
//  Created by Efim Polevoi on 17/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import NIO

let RETRY_BASE_DELAY_MS: Int64 = 50
let RETRY_MAX_DELAY_MS: Int64 = 2000

/// Why a request to Scylla failed on the client's side
///
enum RequestError: Error, CustomStringConvertible {
    case timedOut(TimeAmount)
    case noOpenConnection

    var description: String {
        switch self {
        case .timedOut(let timeout):
            return "no answer from Scylla within \(timeout.nanoseconds / 1_000_000) ms"
        case .noOpenConnection:
            return "every connection to Scylla is closed"
        }
    }
}

/// Fail a request that gets no answer in time.
///
/// A request can go unanswered: Scylla stops responding, as when it was paused mid-load,
/// or a connection stalls. A timeout turns that silent wait into a failure the caller
/// can retry or report.
///
/// - parameters:
///    - future: The request's result.
///    - timeout: How long to wait for it.
///
func withTimeout<T>(_ future: EventLoopFuture<T>, _ timeout: TimeAmount) -> EventLoopFuture<T> {
    let eventLoop = future.eventLoop
    let promise = eventLoop.makePromise(of: T.self)
    let race = Race()
    let timer = eventLoop.scheduleTask(in: timeout) {
        if race.finish() {
            promise.fail(RequestError.timedOut(timeout))
        }
    }
    future.whenComplete { result in
        timer.cancel()
        if race.finish() {
            promise.completeWith(result)
        }
    }
    return promise.futureResult
}

/// Whether a failed request is worth retrying: Scylla's availability, overload and timeout errors,
/// a closed connection, and no answer in time. A request Scylla rejected as invalid would fail again.
///
func isRetryable(_ error: Error) -> Bool {
    if let error = error as? CQLError {
        return error.isRetryable
    }
    if let error = error as? RequestError, case .timedOut = error {
        return true
    }
    return false
}

/// The delay before retrying a request: exponential, with full jitter.
/// The ceiling doubles with each attempt, and the delay is a random point below it,
/// so requests that failed together don't all retry at the same moment.
///
/// - parameters:
///    - attempt: The attempt that failed, counting from 1.
///
func retryDelay(after attempt: Int) -> TimeAmount {
    let ceiling = min(RETRY_BASE_DELAY_MS << min(attempt - 1, 16), RETRY_MAX_DELAY_MS)
    return .milliseconds(Int64.random(in: 0...ceiling))
}

/// Settles the race between a response and its timeout: the first to call `finish()` wins.
/// Both sides run on the same event loop, so the flag needs no lock.
///
private final class Race {
    private var finished = false

    func finish() -> Bool {
        defer { finished = true }
        return !finished
    }
}
