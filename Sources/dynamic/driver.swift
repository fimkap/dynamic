//
//  driver.swift
//  dynamic
//
//  Created by Efim Polevoi on 07/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation
import NIO
import NIOScyllaDB

let SCYLLA_HOSTNAME = "127.0.0.1"
let SCYLLA_PORT = 9042
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
    private let tableName: String
    /// The table for this customer's products, qualified with the keyspace
    private var table: String {
        return "dynamic.c\(self.tableName)"
    }
    
    init(tableName: String) {
        self.tableName = tableName
    }

    func setup() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func shutdown() throws {
        try self.group.syncShutdownGracefully()
        self.group = nil
    }

    /// Open a connection to Scylla and log in
    ///
    private func makeConnection() throws -> ScyllaConnection {
        let address = try SocketAddress.makeAddressResolvingHost(SCYLLA_HOSTNAME, port: SCYLLA_PORT)
        return try ScyllaConnection.connect(to: address, on: self.eventLoop).flatMap { conn in
            conn.authenticate(username: SCYLLA_USERNAME, password: SCYLLA_PASSWORD).map { conn }
        }.wait()
    }

    /// Create a keyspace and a customer table
    ///
    func initKeyspace() throws {
        let conn = try self.makeConnection()
        // Scylla places data with tablets by default, and tablets don't support SimpleStrategy.
        // With NetworkTopologyStrategy, replication_factor applies to every datacenter.
        _ = try conn.query("""
                CREATE KEYSPACE IF NOT EXISTS dynamic
                WITH replication = {
                    'class': 'NetworkTopologyStrategy',
                    'replication_factor' : 1
                    };
                """).wait()
        _ = try conn.query("""
                CREATE TABLE IF NOT EXISTS \(self.table) (
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
    ///    - reader: The csv file, positioned after its header.
    ///
    func dispatchQueries(_ reader: CSVReader) throws {
        // Simplistic implementation of a connection pool.
        // It should enable us to improve load on Scylla for better performance.
        // The driver has no pool of its own, and the one in ScyllaKit didn't compile.
        var pool: [ScyllaConnection] = []
        for _ in 0...MAX_SCYLLA_CONNECTION_COUNT {
            pool.append(try self.makeConnection())
        }

        // We'll use OperationQueue to dispatch queries from multiple threads to improve performance.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = MAX_CONCURRENT_OPERATION_COUNT

        while true {
            let product: Product
            do {
                guard let fields = try reader.next() else {
                    break
                }
                product = try Product(fields: fields)
            } catch let error as CSVReader.CSVError {
                print("error: \(error)")
                continue
            } catch let error as Product.ValidationError {
                print("error: line \(reader.recordLine): \(error)")
                continue
            }
            let query = product.insertStatement(into: self.table)
            queue.addOperation {
                // Note that the library is not mature enough to support batch queries.
                // Randomize the connection selection from the pool and run the query synchronously
                do {
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
