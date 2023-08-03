//
//  driver.swift
//  dynamic
//
//  Created by Efim Polevoi on 07/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation
import ScyllaKit

let SCYLLA_HOSTNAME = "127.0.0.1"
let SCYLLA_USERNAME = "cassandra"
let SCYLLA_PASSWORD = "cassandra"
let MAX_CONCURRENT_OPERATION_COUNT = 64
let MAX_SCYLLA_CONNECTION_COUNT = 10

/// A `ScyllaDriver` is the central type in `dynamic`.
/// Its central function is to dispatch write queries to Scylla DB based on csv file
///
/// The most basic usage of a `ScyllaDriver` is
///
///     driver.dispatchQueries(filePath)
///
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

    /// Create a keyspace and a customer table
    ///
    /// - parameters:
    ///    - tableName: The name for a customer table.
    ///
    func initKeyspace(_ tableName: String) throws {
        let db = ScyllaConnectionSource(configuration: .init(hostname: SCYLLA_HOSTNAME, username: SCYLLA_USERNAME, password: SCYLLA_PASSWORD))
        let conn = try db.makeConnection(logger: Logger(label: "sds"), on: self.eventLoop).wait()
        _ = try conn.query("""
                CREATE KEYSPACE IF NOT EXISTS dynamic
                WITH replication = {
                    'class': 'SimpleStrategy',
                    'replication_factor' : 1
                    };
                """).wait()
        _ = try conn.query("""
                CREATE TABLE IF NOT EXISTS dynamic.c\(tableName) (
                    product_id int PRIMARY KEY,
                    product_name text,
                    product_image_url text,
                    product_price float,
                    product_categories text,
                    product_stock int,
                    ) WITH comment='Product details'
                """).wait()
        _ = conn.close()
    }

    /// Read csv file and dispatch write queries to Scylla DB.
    ///
    /// - parameters:
    ///    - filePath: The path (name) for csv file.
    ///    - tableName: The name for a customer table.
    ///
    func dispatchQueries(_ filePath: String, _ tableName: String) throws {
        let db = ScyllaConnectionSource(configuration: .init(hostname: SCYLLA_HOSTNAME, username: SCYLLA_USERNAME, password: SCYLLA_PASSWORD))
        // Simplistic implementation of a connection pool.
        // It should enable us to improve load on Scylla for better performance.
        // ScyllaKit package has some nice patterns for a built-in connection pool,
        //  but it doesn't compile at the moment.
        var pool: [ScyllaConnection] = []
        for _ in 0...MAX_SCYLLA_CONNECTION_COUNT {
            pool.append(try db.makeConnection(logger: Logger(label: "sds"), on: self.eventLoop).wait())
        }

        // We'll use OperationQueue to dispatch queries from multiple threads to improve performance.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = MAX_CONCURRENT_OPERATION_COUNT

        if freopen(filePath, "r", stdin) == nil {
            perror(filePath)
        }
        // Skip csv header
        _ = readLine()
        
        // Parse csv file line by line not to load the whole file into memory
        while let line = readLine() {
            queue.addOperation {
                // Note that the library is not mature enough to support batch queries.
                // Randomize the connection selection from the pool and run the query synchronously
                do {
                    let query = try CSVParser.parseLine(tableName, line)
                    _ = try pool[Int.random(in: 0 ..< MAX_SCYLLA_CONNECTION_COUNT)].query(query, flags: QueryFlags.none, consistency: Consistency.any).wait()
                } catch {
                    // We need to print the error here because the operation queue doesn't propagate the error to the main thread.
                    print("error: \(error)")
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        for i in 0...MAX_SCYLLA_CONNECTION_COUNT {
            _ = pool[i].close()
        }
    }
}
