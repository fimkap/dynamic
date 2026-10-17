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

    /// Whether every row was written
    var isComplete: Bool {
        return locked { failedCount == 0 && skippedCount == 0 }
    }

    /// The counts, the time taken and the peak memory, then the first rows that failed, if any
    ///
    /// - parameters:
    ///    - seconds: How long reading and writing took.
    ///
    func summary(seconds: Double) -> String {
        return locked {
            let rate = seconds > 0 ? Int(Double(writtenCount) / seconds) : 0
            var text = "Wrote \(writtenCount) rows in \(String(format: "%.1f", seconds)) s (\(rate) rows/s). "
                + "Retries: \(retriedCount). Failed rows: \(failedCount). Skipped as invalid: \(skippedCount). "
                + "Peak memory: \(peakMemory() / 1_048_576) MB."
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

/// The process's peak memory use, in bytes.
/// On macOS that's the peak memory footprint, which counts memory the system has compressed.
/// The resident size doesn't, so under memory pressure it can understate use several times over.
///
func peakMemory() -> Int {
    #if canImport(Darwin)
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? Int(info.ri_lifetime_max_phys_footprint) : 0
    #else
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return usage.ru_maxrss * 1024  // Linux reports kilobytes
    #endif
}
