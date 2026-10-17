import XCTest
import NIOScyllaDB
@testable import dynamic

/// The bytes of PREPARE and EXECUTE, checked against the CQL protocol specification
final class PreparedStatementTests: XCTestCase {
    private func bytes(_ buffer: ByteBuffer) -> [UInt8] {
        var buffer = buffer
        return buffer.readBytes(length: buffer.readableBytes) ?? []
    }

    private func bytes(_ value: CQLValue) -> [UInt8] {
        var buffer = ByteBufferAllocator().buffer(capacity: 16)
        value.write(to: &buffer)
        return bytes(buffer)
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

    func testPrepareBodyIsTheQuery() {
        XCTAssertEqual(bytes(PreparedStatement.prepareBody("SELECT 1")), [0, 0, 0, 8] + Array("SELECT 1".utf8))
    }

    func testPreparedResultGivesTheID() throws {
        let id = try PreparedStatement.preparedID(from: result(kind: 4) { body in
            body.writeInteger(UInt16(3))
            body.writeBytes([0xAB, 0xCD, 0xEF])
            body.writeInteger(Int32(0))  // the metadata that follows isn't read
        })
        XCTAssertEqual(id, [0xAB, 0xCD, 0xEF])
    }

    func testOtherResultToPrepareIsAnError() {
        XCTAssertThrowsError(try PreparedStatement.preparedID(from: result(kind: 1)))
    }

    func testExecuteBodyLayout() {
        let statement = PreparedStatement(id: [0xAB, 0xCD])
        XCTAssertEqual(bytes(statement.executeBody([.int(7), .text("a")], consistency: .one)), [
            0x00, 0x02, 0xAB, 0xCD,                          // the id as [short bytes]
            0x00, 0x01,                                      // consistency ONE
            0x01,                                            // flags: values follow
            0x00, 0x02,                                      // two values
            0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x07,  // int 7
            0x00, 0x00, 0x00, 0x01, 0x61,                    // text "a"
        ])
    }
}
