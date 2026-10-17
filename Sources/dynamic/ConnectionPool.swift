//
//  ConnectionPool.swift
//  dynamic
//
//  Created by Efim Polevoi on 17/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import Foundation
import NIOScyllaDB

/// A `ConnectionPool` hands out connections round robin, skipping closed ones.
/// Each connection carries the insert prepared on it.
///
final class ConnectionPool {
    struct Member {
        let connection: ScyllaConnection
        let insert: PreparedStatement
    }

    private let members: [Member]
    private let lock = NSLock()
    private var nextIndex = 0

    init(_ members: [Member]) {
        self.members = members
    }

    /// The next open connection, or `nil` if every connection is closed.
    /// The reader and the event loops both call it, so it takes a lock.
    ///
    func next() -> Member? {
        lock.lock()
        defer { lock.unlock() }
        for _ in members.indices {
            let member = members[nextIndex]
            nextIndex = (nextIndex + 1) % members.count
            if !member.connection.isClosed {
                return member
            }
        }
        return nil
    }

    /// Call `close()` on every connection. The driver's `close()` doesn't close an open channel,
    /// because its check is inverted, so the sockets close when the event loops shut down.
    /// Calling it still matters: the driver asserts that a connection was closed before it's released.
    ///
    func close() {
        for member in members {
            _ = member.connection.close()
        }
    }
}
