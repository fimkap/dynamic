//
//  driver.swift
//  dynamic
//
//  Created by Efim Polevoi on 07/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation
import ScyllaKit

class ScyllaDriver {
    private var group: EventLoopGroup!
    private var eventLoop: EventLoop {
        return self.group.next()
    }

    func setup() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func shutdown() throws {
        try self.group.syncShutdownGracefully()
        self.group = nil
    }

    func doQuery() throws {
        let db = ScyllaConnectionSource(configuration: .init(hostname: "127.0.0.1", username: "cassandra", password: "cassandra "))
        let conn = try db.makeConnection(logger: Logger(label: "sds"), on: self.eventLoop).wait()
        let result = try conn.query("SELECT cql_version FROM system.local;").wait()
        print(result)

        /* let db = ScyllaConnectionSource( configuration: .init(hostname: "172.17.0.2", username: "cassandra", password: "cassandra", keypspace: nil), on: self.eventLoop) */
        /* let pool = ConnectionPool(config: .init(maxConnections: 12), source: db) */
        /* defer { try! pool.close().wait() } */
        /* for _ in 1...100 { */
        /*     _ = try! pool.withConnection { conn in */
        /*         return conn.query("SELECT cql_version FROM system.local;") */
        /*     }.wait() */
        /* } */
    }
}
