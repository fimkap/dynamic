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

    func doQuery(_ filePath: String) throws {
        let db = ScyllaConnectionSource(configuration: .init(hostname: "127.0.0.1", username: "cassandra", password: "cassandra "))
        let conn = try db.makeConnection(logger: Logger(label: "sds"), on: self.eventLoop).wait()
        /* let result = try conn.query("SELECT cql_version FROM system.local;").wait() */
        let result = try conn.query("""
                CREATE KEYSPACE IF NOT EXISTS dynamic
                WITH replication = {
                    'class': 'SimpleStrategy',
                    'replication_factor' : 1
                    };
                """).wait()
        let result2 = try conn.query("""
                CREATE TABLE IF NOT EXISTS dynamic.customer1 (
                    product_id int PRIMARY KEY,
                    product_name text,
                    product_image_url text,
                    product_price float,
                    product_categories text,
                    product_stock int,
                    ) WITH comment='Product details'
                """).wait()
        print(result)
        print(result2)

        if freopen(filePath, "r", stdin) == nil {
            perror(filePath)
        } else {
            while let line = readLine() {
                /* print(line) */
                
                let product: [String] = line.components(separatedBy: ",")
                /* print(product[0]) */
                /* print(product[1]) */

                let query = "INSERT INTO dynamic.customer1 (product_id, product_name, product_image_url, product_price, product_categories, product_stock) VALUES (\(Int(product[0]) ?? 0), '\(product[1])', '\(product[2])', \(Float(product[3]) ?? 0.0), '\(product[4])', \(Int(product[5]) ?? 0));"
                /* print(query) */

                let result3 = try conn.query(query).wait()
                /* print(result3) */
            }
        }
    }
}
