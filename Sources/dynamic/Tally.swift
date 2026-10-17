//
//  Tally.swift
//  dynamic
//
//  Created by Efim Polevoi on 17/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import Foundation

let MAX_FAILURES_SHOWN = 10

/// A `Tally` counts what happened to the rows.
/// Writes complete on many event loops, so every update takes a lock.
///
final class Tally {
    private let lock = NSLock()
    private var writtenCount = 0
    private var retriedCount = 0
    private var skippedCount = 0
    private var failedCount = 0
    private var failures: [(id: Int32, error: Error)] = []

    func written() {
        locked { writtenCount += 1 }
    }

    func retried() {
        locked { retriedCount += 1 }
    }

    func skipped() {
        locked { skippedCount += 1 }
    }

    func failed(_ id: Int32, _ error: Error) {
        locked {
            failedCount += 1
            if failures.count < MAX_FAILURES_SHOWN {
                failures.append((id, error))
            }
        }
    }

    /// The counts, then the first rows that failed, if any
    var summary: String {
        return locked {
            var text = "Wrote \(writtenCount) rows; retried \(retriedCount) writes; "
                + "\(failedCount) rows failed; \(skippedCount) skipped as invalid."
            for failure in failures {
                text += "\n  product_id \(failure.id): \(failure.error)"
            }
            if failedCount > failures.count {
                text += "\n  ..."
            }
            if failedCount > 0 {
                text += "\nThe inserts are idempotent, so running the file again is safe."
            }
            return text
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
