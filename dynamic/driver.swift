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
let MAX_CONCURRENT_OPERATION_COUNT = 32

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
        let conn = try db.makeConnection(logger: Logger(label: "sds"), on: self.eventLoop).wait()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = MAX_CONCURRENT_OPERATION_COUNT

        if freopen(filePath, "r", stdin) == nil {
            perror(filePath)
        }
        while let line = readLine() {
            queue.addOperation {
            
                let product: [String] = line.components(separatedBy: ",")
                
                let query = "INSERT INTO dynamic.c\(tableName) (product_id, product_name, product_image_url, product_price, product_categories, product_stock) VALUES (\(Int(product[0]) ?? 0), '\(product[1])', '\(product[2])', \(Float(product[3]) ?? 0.0), '\(product[4])', \(Int(product[5]) ?? 0));"
                
                do {
                    _ = try conn.query(query, flags: QueryFlags.none, consistency: Consistency.any).wait()
                } catch {
                    print("error: \(error)")
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        _ = conn.close()
    }
}
