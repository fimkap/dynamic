import XCTest
import NIO
import NIOScyllaDB
@testable import dynamic

/// The request layer, run against SwiftNIO's in-memory channel: no server and no network.
/// Each test pins down something the driver got wrong.
final class CQLConnectionTests: XCTestCase {
    private func frame(_ opcode: ScyllaMessage.protocolOpcode, stream: UInt16, _ write: (inout ByteBuffer) -> Void = { _ in }) -> ScyllaMessage {
        var body = ByteBufferAllocator().buffer(capacity: 16)
        write(&body)
        return ScyllaMessage(version: .response, flags: .none, streamID: stream, opcode: opcode, body: body)
    }

    private func request(on channel: EmbeddedChannel) -> CQLRequestHandler.Request {
        let message = ScyllaMessage(version: .request, flags: .none, streamID: 0, opcode: .QUERY,
                                    body: ByteBufferAllocator().buffer(capacity: 0))
        return CQLRequestHandler.Request(message: message, response: channel.eventLoop.makePromise())
    }

    /// Send a request through the handler, and return its response and the stream id it was given
    private func send(on channel: EmbeddedChannel) throws -> (response: EventLoopFuture<ScyllaMessage>, stream: UInt16) {
        let request = self.request(on: channel)
        try channel.writeOutbound(request)
        let written = try XCTUnwrap(channel.readOutbound(as: ScyllaMessage.self))
        return (request.response.futureResult, written.streamID)
    }

    /// The future's result so far. On an `EmbeddedChannel`, callbacks run synchronously.
    private func outcome<T>(of future: EventLoopFuture<T>) -> Result<T, Error>? {
        var outcome: Result<T, Error>?
        future.whenComplete { outcome = $0 }
        return outcome
    }

    func testResponsesMatchRequestsByStreamID() throws {
        let channel = EmbeddedChannel(handler: CQLRequestHandler())
        let first = try send(on: channel)
        let second = try send(on: channel)
        XCTAssertEqual([first.stream, second.stream], [0, 1])

        try channel.writeInbound(frame(.RESULT, stream: 1))  // the second answer arrives first
        XCTAssertNil(outcome(of: first.response))
        XCTAssertNotNil(try outcome(of: second.response)?.get())
        try channel.writeInbound(frame(.RESULT, stream: 0))
        XCTAssertNotNil(try outcome(of: first.response)?.get())
        _ = try channel.finish()
    }

    func testErrorFrameFailsTheRequest() throws {
        // The driver logged an error frame and left the request waiting forever
        let channel = EmbeddedChannel(handler: CQLRequestHandler())
        let sent = try send(on: channel)
        try channel.writeInbound(frame(.ERROR, stream: sent.stream) { body in
            body.writeInteger(Int32(0x1100))
            body.writeShortString("Operation timed out")
        })
        guard case .failure(let error)? = outcome(of: sent.response), case CQLError.server(let code, let message) = error else {
            return XCTFail("expected a server error")
        }
        XCTAssertEqual(code, 0x1100)
        XCTAssertEqual(message, "Operation timed out")
        _ = try channel.finish()
    }

    func testWritesComplete() throws {
        // The driver dropped this promise, and every request leaked the future and its callbacks
        let channel = EmbeddedChannel(handler: CQLRequestHandler())
        let written = channel.writeAndFlush(request(on: channel))
        XCTAssertNoThrow(try outcome(of: written)?.get())
        XCTAssertNotNil(outcome(of: written))
        _ = try channel.finish()
    }

    func testIDIsReusedOnlyAfterItsResponse() throws {
        // The driver's counter wrapped around and reused ids of requests still waiting
        let channel = EmbeddedChannel(handler: CQLRequestHandler())
        let first = try send(on: channel)
        _ = try send(on: channel)
        try channel.writeInbound(frame(.RESULT, stream: first.stream))
        let third = try send(on: channel)
        let fourth = try send(on: channel)
        XCTAssertEqual([third.stream, fourth.stream], [0, 2])
        _ = try channel.finish()
    }

    func testUnknownFramesAreIgnored() throws {
        // The driver crashed on a response it had no request for
        let channel = EmbeddedChannel(handler: CQLRequestHandler())
        try channel.writeInbound(frame(.RESULT, stream: 5))      // nothing waits on 5
        try channel.writeInbound(frame(.EVENT, stream: 0xFFFF))  // id -1: an event from the server
        XCTAssertEqual(try send(on: channel).stream, 0)
        _ = try channel.finish()
    }

    func testClosingFailsWaitingRequests() throws {
        let channel = EmbeddedChannel(handler: CQLRequestHandler())
        let sent = try send(on: channel)
        _ = try channel.finish()
        guard case .failure(let error)? = outcome(of: sent.response), case CQLError.connectionClosed = error else {
            return XCTFail("expected the request to fail when the connection closed")
        }
    }

    func testFrameLayout() throws {
        var body = ByteBufferAllocator().buffer(capacity: 2)
        body.writeBytes([0xAA, 0xBB])
        let message = ScyllaMessage(version: .request, flags: .none, streamID: 0x0102, opcode: .QUERY, body: body)
        var out = ByteBufferAllocator().buffer(capacity: 16)
        try CQLFrameEncoder().encode(data: message, out: &out)
        XCTAssertEqual(out.readBytes(length: out.readableBytes), [
            0x03,                    // protocol version 3, a request
            0x00,                    // flags
            0x01, 0x02,              // stream id
            0x07,                    // opcode QUERY
            0x00, 0x00, 0x00, 0x02,  // body length
            0xAA, 0xBB,              // body
        ])
    }

    func testWhichErrorsAreRetried() {
        XCTAssertTrue(isRetryable(CQLError.server(code: 0x1001, message: "overloaded")))
        XCTAssertTrue(isRetryable(CQLError.server(code: 0x1100, message: "write timeout")))
        XCTAssertFalse(isRetryable(CQLError.server(code: 0x2200, message: "invalid query")))
        XCTAssertTrue(isRetryable(RequestError.timedOut(.seconds(5))))
        XCTAssertFalse(isRetryable(RequestError.noOpenConnection))
    }
}
