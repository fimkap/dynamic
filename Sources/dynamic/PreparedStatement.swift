//
//  PreparedStatement.swift
//  dynamic
//
//  Created by Efim Polevoi on 17/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import NIO
import NIOScyllaDB

/// A `PreparedStatement` is a query that Scylla parsed once, on one connection.
/// Each execution sends only the statement's id and the values bound to its `?` markers,
/// so values never become part of the query text.
///
/// The most basic usage of a `PreparedStatement` is
///
///     let insert = try PreparedStatement.prepare(query, on: connection).wait()
///     try insert.execute([.int(1), .text("iPhone 11")], consistency: .one, on: connection).wait()
///
struct PreparedStatement {
    /// The id Scylla gave the statement
    let id: [UInt8]

    /// Prepare a query on a connection.
    ///
    /// - parameters:
    ///    - query: The query, with a `?` for each value.
    ///    - connection: The connection to prepare it on. Execute it on the same connection.
    ///
    static func prepare(_ query: String, on connection: CQLConnection) -> EventLoopFuture<PreparedStatement> {
        return connection.request(.PREPARE, prepareBody(query)).flatMapThrowing { response in
            return PreparedStatement(id: try preparedID(from: response))
        }
    }

    /// Execute the statement.
    ///
    /// - parameters:
    ///    - values: A value for each `?` in the query, in order.
    ///    - consistency: How many replicas must acknowledge the write.
    ///    - connection: The connection the statement was prepared on.
    ///
    func execute(_ values: [CQLValue], consistency: Consistency, on connection: CQLConnection) -> EventLoopFuture<Void> {
        return connection.request(.EXECUTE, executeBody(values, consistency: consistency)).map { _ in }
    }

    /// The body of PREPARE: the query as a [long string]
    ///
    static func prepareBody(_ query: String) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4 + query.utf8.count)
        body.writeLongString(query)
        return body
    }

    /// Read the statement's id from Scylla's answer to PREPARE: a RESULT of kind Prepared,
    /// which starts with the id as [short bytes]
    ///
    static func preparedID(from response: ScyllaMessage) throws -> [UInt8] {
        var body = response.body
        guard response.opcode == .RESULT,
              body.readInteger(as: Int32.self) == RESULT_KIND_PREPARED,
              let length = body.readInteger(as: UInt16.self),
              let id = body.readBytes(length: Int(length)) else {
            throw CQLError.unexpectedResponse(response.opcode)
        }
        return id
    }

    /// The body of EXECUTE: the statement's id as [short bytes], then the query parameters:
    /// the consistency as [short], a flags [byte] saying that values follow,
    /// their count as [short], and each value as [bytes]
    ///
    func executeBody(_ values: [CQLValue], consistency: Consistency) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 64)
        body.writeInteger(UInt16(id.count))
        body.writeBytes(id)
        body.writeInteger(consistency.rawValue)
        body.writeInteger(QUERY_FLAG_VALUES)
        body.writeInteger(UInt16(values.count))
        for value in values {
            value.write(to: &body)
        }
        return body
    }
}

/// A value bound to a `?` in a prepared statement
///
enum CQLValue: Equatable {
    case int(Int32)
    case float(Float)
    case text(String)

    /// Write the value as CQL [bytes]: its length as a 4-byte integer, then the value.
    /// Numbers are big-endian, a float is its IEEE 754 bit pattern, and text is UTF-8.
    ///
    func write(to buffer: inout ByteBuffer) {
        switch self {
        case .int(let value):
            buffer.writeInteger(Int32(4))
            buffer.writeInteger(value)
        case .float(let value):
            buffer.writeInteger(Int32(4))
            buffer.writeInteger(value.bitPattern)
        case .text(let value):
            buffer.writeInteger(Int32(value.utf8.count))
            buffer.writeString(value)
        }
    }
}

/// The RESULT kind of a prepared statement
private let RESULT_KIND_PREPARED: Int32 = 0x0004
/// The query flag saying that values follow
private let QUERY_FLAG_VALUES: UInt8 = 0x01
