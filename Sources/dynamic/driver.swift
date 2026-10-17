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
let CONNECTION_COUNT = 8
let MAX_WRITES_IN_FLIGHT = 512
let MAX_ATTEMPTS = 5
let WRITE_TIMEOUT = TimeAmount.seconds(5)
let SCHEMA_TIMEOUT = TimeAmount.seconds(30)

/// A `ScyllaDriver` is the central type in `dynamic`.
/// Its central function is to dispatch write queries to Scylla DB based on csv file
///
/// The most basic usage of a `ScyllaDriver` is
///
///     driver.dispatchQueries(reader)
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
    private let tally = Tally()
    
    init(tableName: String) {
        self.tableName = tableName
    }

    /// Start an event loop per CPU core. Each connection belongs to one loop,
    /// which does its network I/O and runs the callbacks of its requests.
    ///
    func setup() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
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
        _ = try withTimeout(conn.query("""
                CREATE KEYSPACE IF NOT EXISTS dynamic
                WITH replication = {
                    'class': 'NetworkTopologyStrategy',
                    'replication_factor' : 1
                    };
                """), SCHEMA_TIMEOUT).wait()
        _ = try withTimeout(conn.query("""
                CREATE TABLE IF NOT EXISTS \(self.table) (
                    product_id int PRIMARY KEY,
                    product_name text,
                    product_image_url text,
                    product_price float,
                    product_categories text,
                    product_stock int,
                    ) WITH comment='Product details'
                """), SCHEMA_TIMEOUT).wait()
        _ = conn.close()
    }

    /// Read csv file and dispatch write queries to Scylla DB.
    ///
    /// Writes are asynchronous, and at most `MAX_WRITES_IN_FLIGHT` are outstanding at a time:
    /// when that many are in flight, the next row isn't read until one of them completes.
    /// That's the backpressure. Memory stays flat however large the file is,
    /// and Scylla is never sent more than it is already handling.
    ///
    /// - parameters:
    ///    - reader: The csv file, positioned after its header.
    ///
    func dispatchQueries(_ reader: CSVReader) throws {
        let pool = try self.makePool()
        let slots = DispatchSemaphore(value: MAX_WRITES_IN_FLIGHT)
        let inFlight = DispatchGroup()

        while true {
            let product: Product
            do {
                guard let fields = try reader.next() else {
                    break
                }
                product = try Product(fields: fields)
            } catch let error as CSVReader.CSVError {
                print("error: \(error)")
                self.tally.skipped()
                continue
            } catch let error as Product.ValidationError {
                print("error: line \(reader.recordLine): \(error)")
                self.tally.skipped()
                continue
            }
            slots.wait()
            inFlight.enter()
            self.write(product, using: pool).whenComplete { result in
                switch result {
                case .success:
                    self.tally.written()
                case .failure(let error):
                    self.tally.failed(product.id, error)
                }
                slots.signal()
                inFlight.leave()
            }
        }
        inFlight.wait()
        pool.close()
        print(self.tally.summary)
    }

    /// Open the connections that writes go out on, and prepare the insert on each,
    /// so Scylla parses it once per connection rather than once per row
    ///
    private func makePool() throws -> ConnectionPool {
        let insert = Product.insertQuery(into: self.table)
        var members: [ConnectionPool.Member] = []
        for _ in 0..<CONNECTION_COUNT {
            let connection = try self.makeConnection()
            let statement = try withTimeout(PreparedStatement.prepare(insert, on: connection), SCHEMA_TIMEOUT).wait()
            members.append(ConnectionPool.Member(connection: connection, insert: statement))
        }
        return ConnectionPool(members)
    }

    /// Write a product, retrying after a growing delay if an attempt fails or times out.
    /// Retrying is safe because the insert is idempotent: writing a row again with the same
    /// primary key stores the same values, even if an earlier attempt did reach Scylla.
    ///
    /// Each write waits for consistency ONE: the replica that owns the row confirms it.
    /// ANY, used before, also accepts a write that was only stored as a hint for later delivery.
    ///
    /// Rows go out one at a time rather than in batches. Each row has its own partition key,
    /// and a batch across partitions makes one node coordinate all of them,
    /// which is slower than sending the rows directly.
    ///
    /// - parameters:
    ///    - product: The row to write.
    ///    - pool: The connections to use; each attempt takes the next one.
    ///    - attempt: The attempt number, counting from 1.
    ///
    private func write(_ product: Product, using pool: ConnectionPool, attempt: Int = 1) -> EventLoopFuture<Void> {
        guard let member = pool.next() else {
            return self.eventLoop.makeFailedFuture(RequestError.noOpenConnection)
        }
        let eventLoop = member.connection.eventLoop
        let request = member.insert.execute(product.values, consistency: .one, on: member.connection)
        return withTimeout(request, WRITE_TIMEOUT).flatMapError { error in
            guard attempt < MAX_ATTEMPTS else {
                return eventLoop.makeFailedFuture(error)
            }
            self.tally.retried()
            return eventLoop.flatScheduleTask(in: retryDelay(after: attempt)) {
                self.write(product, using: pool, attempt: attempt + 1)
            }.futureResult
        }
    }
}
