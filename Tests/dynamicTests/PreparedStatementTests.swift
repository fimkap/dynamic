import XCTest
import NIOScyllaDB
@testable import dynamic

final class PreparedStatementTests: XCTestCase {
    private func bytes(_ value: CQLValue) -> [UInt8] {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        value.write(to: &buffer)
        return buffer.readBytes(length: buffer.readableBytes) ?? []
    }

    private func result(kind: Int32, _ write: (inout ByteBuffer) -> Void = { _ in }) -> ScyllaMessage {
        var body = ByteBufferAllocator().buffer(capacity: 16)
        body.writeInteger(kind)
        write(&body)
        return ScyllaMessage(version: .response, flags: .none, streamID: 1, opcode: .RESULT, body: body)
    }

    func testIntIsFourBigEndianBytes() {
        XCTAssertEqual(bytes(.int(650)), [0, 0, 0, 4, 0x00, 0x00, 0x02, 0x8A])
        XCTAssertEqual(bytes(.int(-1)), [0, 0, 0, 4, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testFloatIsItsIEEE754BitPattern() {
        XCTAssertEqual(bytes(.float(650)), [0, 0, 0, 4, 0x44, 0x22, 0x80, 0x00])
    }

    func testTextIsUTF8AndItsLengthCountsBytes() {
        XCTAssertEqual(bytes(.text("Café")), [0, 0, 0, 5, 0x43, 0x61, 0x66, 0xC3, 0xA9])
    }

    func testPrepareMessageCarriesTheQuery() throws {
        let message = try XCTUnwrap(PrepareRequest(query: "SELECT 1").start().first)
        XCTAssertEqual(message.opcode, .PREPARE)
        var body = message.body
        XCTAssertEqual(body.readInteger(as: Int32.self), 8)
        XCTAssertEqual(body.readString(length: 8), "SELECT 1")
        XCTAssertEqual(body.readableBytes, 0)
    }

    func testPreparedResultGivesTheID() throws {
        let request = PrepareRequest(query: "SELECT 1")
        let done = try request.respond(to: result(kind: 4) { body in
            body.writeInteger(UInt16(3))
            body.writeBytes([0xAB, 0xCD, 0xEF])
            body.writeInteger(Int32(0))  // the metadata that follows isn't read
        })
        XCTAssertNil(done)
        XCTAssertEqual(request.id, [0xAB, 0xCD, 0xEF])
    }

    func testOtherResultToPrepareIsAnError() {
        XCTAssertThrowsError(try PrepareRequest(query: "SELECT 1").respond(to: result(kind: 1)))
    }

    func testExecuteMessageLayout() throws {
        let request = ExecuteRequest(id: [0xAB, 0xCD], values: [.int(7), .text("a")], consistency: .one)
        let message = try XCTUnwrap(request.start().first)
        XCTAssertEqual(message.opcode, .EXECUTE)
        var body = message.body
        XCTAssertEqual(body.readBytes(length: body.readableBytes), [
            0x00, 0x02, 0xAB, 0xCD,                          // the id as [short bytes]
            0x00, 0x01,                                      // consistency ONE
            0x01,                                            // flags: values follow
            0x00, 0x02,                                      // two values
            0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x07,  // int 7
            0x00, 0x00, 0x00, 0x01, 0x61,                    // text "a"
        ])
    }
}
