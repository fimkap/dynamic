//
//  CQLConnection.swift
//  dynamic
//
//  Created by Efim Polevoi on 18/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import Foundation
import NIO
import NIOScyllaDB

/// A `CQLConnection` is a connection to Scylla with a request layer of our own.
///
/// The driver's request layer never completes a request that Scylla answered with an error,
/// reuses request ids under load, never closes an open connection, and leaks memory on every
/// request. Of the driver, this uses only the message type and the frame decoder.
///
/// The most basic usage of a `CQLConnection` is
///
///     let connection = try CQLConnection.connect(host: host, port: port, username: user, password: password, on: eventLoop).wait()
///     let response = try connection.query("SELECT now() FROM system.local").wait()
///
final class CQLConnection {
    private let channel: Channel

    var eventLoop: EventLoop {
        return channel.eventLoop
    }

    var isClosed: Bool {
        return !channel.isActive
    }

    private init(channel: Channel) {
        self.channel = channel
    }

    /// Connect to Scylla and complete the CQL handshake.
    ///
    static func connect(host: String, port: Int, username: String, password: String, on eventLoop: EventLoop) -> EventLoopFuture<CQLConnection> {
        return ClientBootstrap(group: eventLoop)
            .channelInitializer { channel in
                // The initializer runs on the channel's event loop, so the handlers go in synchronously
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(ScyllaMessageDecoder()),
                        MessageToByteHandler(CQLFrameEncoder()),
                        CQLRequestHandler(),
                    ])
                }
            }
            .connect(host: host, port: port)
            .flatMap { channel in
                let connection = CQLConnection(channel: channel)
                return connection.startup(username: username, password: password).map { connection }
            }
    }

    /// Send a request and get its response.
    /// The future fails with a `CQLError` when Scylla answers with an error.
    ///
    func request(_ opcode: ScyllaMessage.protocolOpcode, _ body: ByteBuffer) -> EventLoopFuture<ScyllaMessage> {
        let response = channel.eventLoop.makePromise(of: ScyllaMessage.self)
        let message = ScyllaMessage(version: .request, flags: .none, streamID: 0, opcode: opcode, body: body)
        channel.writeAndFlush(CQLRequestHandler.Request(message: message, response: response)).cascadeFailure(to: response)
        return response.futureResult
    }

    /// Run a statement without values, such as a schema change.
    ///
    func query(_ text: String, consistency: Consistency = .one) -> EventLoopFuture<ScyllaMessage> {
        var body = ByteBufferAllocator().buffer(capacity: text.utf8.count + 7)
        body.writeLongString(text)
        body.writeInteger(consistency.rawValue)
        body.writeInteger(UInt8(0))  // flags: no values
        return request(.QUERY, body)
    }

    func close() -> EventLoopFuture<Void> {
        return channel.close()
    }

    /// The CQL handshake: STARTUP, then a password if Scylla asks for one
    ///
    private func startup(username: String, password: String) -> EventLoopFuture<Void> {
        var options = ByteBufferAllocator().buffer(capacity: 32)
        options.writeInteger(UInt16(1))  // a string map with one entry
        options.writeShortString("CQL_VERSION")
        options.writeShortString("3.0.0")
        return request(.STARTUP, options).flatMap { response in
            switch response.opcode {
            case .READY:
                return self.eventLoop.makeSucceededFuture(())
            case .AUTHENTICATE:
                // SASL PLAIN: an empty identity, the user name and the password, separated by NUL bytes
                let credentials = "\0\(username)\0\(password)"
                var token = ByteBufferAllocator().buffer(capacity: 4 + credentials.utf8.count)
                token.writeInteger(Int32(credentials.utf8.count))
                token.writeString(credentials)
                return self.request(.AUTH_RESPONSE, token).flatMapThrowing { response in
                    guard response.opcode == .AUTH_SUCCESS else {
                        throw CQLError.unexpectedResponse(response.opcode)
                    }
                }
            default:
                return self.eventLoop.makeFailedFuture(CQLError.unexpectedResponse(response.opcode))
            }
        }
    }
}

/// A `CQLRequestHandler` runs many requests on one connection at once. Each request gets a
/// stream id, and Scylla's response carries the same id, so responses can arrive in any order.
///
final class CQLRequestHandler: ChannelDuplexHandler {
    typealias InboundIn = ScyllaMessage
    typealias OutboundIn = Request
    typealias OutboundOut = ScyllaMessage

    struct Request {
        var message: ScyllaMessage
        let response: EventLoopPromise<ScyllaMessage>
    }

    /// Ids 0 to 32767. Protocol v3 reserves negative ids for messages the server starts,
    /// and an id is free again only once its response has arrived.
    private var freeIDs = Array((0...UInt16(Int16.max)).reversed())
    private var waiting = [EventLoopPromise<ScyllaMessage>?](repeating: nil, count: Int(Int16.max) + 1)

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var request = unwrapOutboundIn(data)
        guard let id = freeIDs.popLast() else {
            promise?.fail(CQLError.tooManyRequests)  // the caller's response fails with it
            return
        }
        waiting[Int(id)] = request.response
        request.message.streamID = id
        // Passing the promise on means the write completes. The driver dropped it, and a
        // future that never completes keeps itself and its callbacks in memory.
        context.write(wrapOutboundOut(request.message), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        let id = Int(message.streamID)
        guard id < waiting.count, let response = waiting[id] else {
            return  // an event, or a response to a request that already failed
        }
        waiting[id] = nil
        freeIDs.append(message.streamID)
        if message.opcode == .ERROR {
            response.fail(CQLError(errorFrame: message))
        } else {
            response.succeed(message)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failWaiting(CQLError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failWaiting(error)
        context.close(promise: nil)
    }

    private func failWaiting(_ error: Error) {
        for id in waiting.indices {
            if let response = waiting[id] {
                waiting[id] = nil
                freeIDs.append(UInt16(id))
                response.fail(error)
            }
        }
    }
}

/// A `CQLFrameEncoder` writes a message as a CQL frame:
/// version, flags, stream id, opcode, body length, then the body.
///
final class CQLFrameEncoder: MessageToByteEncoder {
    typealias OutboundIn = ScyllaMessage

    func encode(data message: ScyllaMessage, out: inout ByteBuffer) throws {
        var body = message.body
        out.writeInteger(message.version.rawValue)
        out.writeInteger(message.flags.rawValue)
        out.writeInteger(message.streamID)
        out.writeInteger(message.opcode.rawValue)
        out.writeInteger(Int32(body.readableBytes))
        out.writeBuffer(&body)
    }
}

/// An error Scylla sent in place of a result, or a failure on the client's side
///
enum CQLError: Error, CustomStringConvertible {
    case server(code: Int32, message: String)
    case unexpectedResponse(ScyllaMessage.protocolOpcode)
    case tooManyRequests
    case connectionClosed

    /// Read an ERROR frame: a 4-byte error code, then the message as a [string]
    ///
    init(errorFrame: ScyllaMessage) {
        var body = errorFrame.body
        let code = body.readInteger(as: Int32.self) ?? -1
        var message = ""
        if let length = body.readInteger(as: UInt16.self), let text = body.readString(length: Int(length)) {
            message = text
        }
        self = .server(code: code, message: message)
    }

    /// Whether trying again may succeed. Scylla's error codes from 0x1000 to 0x1FFF are
    /// about availability, overload and timeouts. From 0x2000 up the request itself is wrong,
    /// such as a syntax error, and it would fail again.
    ///
    var isRetryable: Bool {
        switch self {
        case .server(let code, _):
            return code == 0 || (0x1000..<0x2000).contains(code)
        case .tooManyRequests, .connectionClosed:
            return true
        case .unexpectedResponse:
            return false
        }
    }

    var description: String {
        switch self {
        case .server(let code, let message):
            return "Scylla error \(String(format: "0x%04X", code)): \(message)"
        case .unexpectedResponse(let opcode):
            return "unexpected response \(opcode)"
        case .tooManyRequests:
            return "more than 32,768 requests waiting on one connection"
        case .connectionClosed:
            return "the connection to Scylla closed"
        }
    }
}

extension ByteBuffer {
    /// Write a CQL [string]: a 2-byte length, then UTF-8
    mutating func writeShortString(_ string: String) {
        writeInteger(UInt16(string.utf8.count))
        writeString(string)
    }

    /// Write a CQL [long string]: a 4-byte length, then UTF-8
    mutating func writeLongString(_ string: String) {
        writeInteger(Int32(string.utf8.count))
        writeString(string)
    }
}
