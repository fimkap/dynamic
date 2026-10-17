import XCTest
@testable import dynamic

final class CSVReaderTests: XCTestCase {
    /// Read every record. The text is read with several chunk sizes, down to a byte at a time,
    /// so records and multi-byte characters get split across chunks; all must agree.
    private func records(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [[String]] {
        var results: [[[String]]] = []
        for chunkSize in [1, 2, 3, 7, 64 * 1024] {
            let reader = CSVReader(text: text, chunkSize: chunkSize)
            var records: [[String]] = []
            while let fields = try reader.next() {
                records.append(fields)
            }
            results.append(records)
        }
        for other in results.dropFirst() {
            XCTAssertEqual(other, results[0], "chunk sizes disagree", file: file, line: line)
        }
        return results[0]
    }

    func testPlainFields() throws {
        XCTAssertEqual(try records("a,b,c\n1,2,3\n"), [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testWhitespaceAroundFieldsIsIgnored() throws {
        XCTAssertEqual(try records("123, iPhone11,  tablet , 250\n"), [["123", "iPhone11", "tablet", "250"]])
    }

    func testQuotedFieldKeepsCommasAndWhitespace() throws {
        XCTAssertEqual(try records("1, \"Watch, Series 9\" ,\" padded \"\n"), [["1", "Watch, Series 9", " padded "]])
    }

    func testDoubledQuoteIsOneQuote() throws {
        XCTAssertEqual(try records("\"AirPods \"\"Pro\"\"\",x\n"), [["AirPods \"Pro\"", "x"]])
    }

    func testLineBreakInsideQuotes() throws {
        XCTAssertEqual(try records("a,\"two\nlines\"\nb,c\n"), [["a", "two\nlines"], ["b", "c"]])
    }

    func testCRLFLineEndings() throws {
        XCTAssertEqual(try records("a,b\r\n\"x\r\ny\",z\r\n"), [["a", "b"], ["x\r\ny", "z"]])
    }

    func testEmptyFields() throws {
        XCTAssertEqual(try records("a,,c\na,b,\n,\n"), [["a", "", "c"], ["a", "b", ""], ["", ""]])
    }

    func testLastRecordWithoutLineBreak() throws {
        XCTAssertEqual(try records("a,b\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testBlankLinesAreSkipped() throws {
        XCTAssertEqual(try records("a,b\n\n   \nc,d\n"), [["a", "b"], ["c", "d"]])
    }

    func testEmptyInput() throws {
        XCTAssertEqual(try records(""), [])
        XCTAssertEqual(try records("\n\n"), [])
    }

    func testMultiByteCharacters() throws {
        XCTAssertEqual(try records("Café,\"😀, ok\"\n"), [["Café", "😀, ok"]])
    }

    func testByteOrderMarkIsSkipped() throws {
        XCTAssertEqual(try records("\u{FEFF}product_id,name\n"), [["product_id", "name"]])
    }

    func testRecordLineCountsLineBreaksInsideQuotes() throws {
        let reader = CSVReader(text: "a,\"x\ny\"\n\nb,c\n")
        _ = try reader.next()
        XCTAssertEqual(reader.recordLine, 1)
        _ = try reader.next()
        XCTAssertEqual(reader.recordLine, 4)
    }

    func testTextAfterClosingQuoteIsAnErrorAndReadingContinues() throws {
        let reader = CSVReader(text: "\"a\"x,b\nc,d\n")
        XCTAssertThrowsError(try reader.next()) { error in
            guard case CSVReader.CSVError.textAfterClosingQuote(line: 1) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try reader.next(), ["c", "d"])
    }

    func testUnterminatedQuoteIsAnError() throws {
        let reader = CSVReader(text: "a,b\nc,\"d\ne\n")
        XCTAssertEqual(try reader.next(), ["a", "b"])
        XCTAssertThrowsError(try reader.next()) { error in
            guard case CSVReader.CSVError.unterminatedQuote(line: 2) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertNil(try reader.next())
    }

    func testReadsFromFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("CSVReaderTests-\(UUID().uuidString).csv").path
        try "a,b\nc,d\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = try CSVReader(path: path, chunkSize: 3)
        XCTAssertEqual(try reader.next(), ["a", "b"])
        XCTAssertEqual(try reader.next(), ["c", "d"])
        XCTAssertNil(try reader.next())
    }
}
