//
//  PreparedStatement.swift
//  dynamic
//
//  Created by Efim Polevoi on 17/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import Logging
import NIOScyllaDB

/// A `PreparedStatement` is a query that Scylla parsed once, on one connection.
/// Each execution sends only the statement's id and the values bound to its `?` markers,
/// so values never become part of the query text.
///
/// The driver doesn't support prepared statements, but a connection sends any `ScyllaRequest`,
/// so the PREPARE and EXECUTE messages of the CQL binary protocol are built here,
/// in version 3, the version the driver speaks.
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
    static func prepare(_ query: String, on connection: ScyllaConnection) -> EventLoopFuture<PreparedStatement> {
        let request = PrepareRequest(query: query)
        return connection.send(request).flatMapThrowing {
            guard let id = request.id else {
                throw PrepareRequest.ResponseError.notPrepared
            }
            return PreparedStatement(id: id)
        }
    }

    /// Execute the statement.
    ///
    /// - parameters:
    ///    - values: A value for each `?` in the query, in order.
    ///    - consistency: How many replicas must acknowledge the write.
    ///    - connection: The connection the statement was prepared on.
    ///
    func execute(_ values: [CQLValue], consistency: Consistency, on connection: ScyllaConnection) -> EventLoopFuture<Void> {
        return connection.send(ExecuteRequest(id: id, values: values, consistency: consistency))
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

/// The PREPARE request carries the query as a [long string].
/// Scylla answers with a RESULT of kind Prepared, which starts with the statement's id as [short bytes].
///
final class PrepareRequest: ScyllaRequest {
    enum ResponseError: Error {
        case notPrepared
    }

    let query: String
    private(set) var id: [UInt8]?

    init(query: String) {
        self.query = query
    }

    func start() throws -> [ScyllaMessage] {
        var body = ByteBufferAllocator().buffer(capacity: 4 + query.utf8.count)
        body.writeInteger(Int32(query.utf8.count))
        body.writeString(query)
        return [ScyllaMessage(version: .request, flags: .none, streamID: 0, opcode: .PREPARE, body: body)]
    }

    func respond(to message: ScyllaMessage) throws -> [ScyllaMessage]? {
        var body = message.body
        guard message.opcode == .RESULT,
              body.readInteger(as: Int32.self) == RESULT_KIND_PREPARED,
              let length = body.readInteger(as: UInt16.self),
              let id = body.readBytes(length: Int(length)) else {
            throw ResponseError.notPrepared
        }
        self.id = id
        return nil
    }

    func log(to logger: Logger) {
        logger.debug("PREPARE \(query)")
    }
}

/// The EXECUTE request carries the statement's id as [short bytes], then the query parameters:
/// the consistency as [short], a flags [byte] saying that values follow, their count as [short],
/// and each value as [bytes].
///
final class ExecuteRequest: ScyllaRequest {
    let id: [UInt8]
    let values: [CQLValue]
    let consistency: Consistency

    init(id: [UInt8], values: [CQLValue], consistency: Consistency) {
        self.id = id
        self.values = values
        self.consistency = consistency
    }

    func start() throws -> [ScyllaMessage] {
        var body = ByteBufferAllocator().buffer(capacity: 64)
        body.writeInteger(UInt16(id.count))
        body.writeBytes(id)
        body.writeInteger(consistency.rawValue)
        body.writeInteger(QUERY_FLAG_VALUES)
        body.writeInteger(UInt16(values.count))
        for value in values {
            value.write(to: &body)
        }
        return [ScyllaMessage(version: .request, flags: .none, streamID: 0, opcode: .EXECUTE, body: body)]
    }

    /// Scylla answers an INSERT with a RESULT of kind Void, so any result completes the request.
    func respond(to message: ScyllaMessage) throws -> [ScyllaMessage]? {
        return nil
    }

    func log(to logger: Logger) {
        logger.debug("EXECUTE \(values)")
    }
}

/// The RESULT kind of a prepared statement
private let RESULT_KIND_PREPARED: Int32 = 0x0004
/// The query flag saying that values follow
private let QUERY_FLAG_VALUES: UInt8 = 0x01
