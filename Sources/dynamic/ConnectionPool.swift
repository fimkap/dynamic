//
//  ConnectionPool.swift
//  dynamic
//
//  Created by Efim Polevoi on 17/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import Foundation

/// A `ConnectionPool` hands out connections round robin, skipping closed ones.
/// Each connection carries the insert prepared on it.
///
final class ConnectionPool {
    struct Member {
        let connection: CQLConnection
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

    /// Close every connection
    ///
    func close() {
        for member in members {
            _ = member.connection.close()
        }
    }
}
