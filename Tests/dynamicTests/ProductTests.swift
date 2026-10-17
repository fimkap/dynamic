import XCTest
@testable import dynamic

final class ProductTests: XCTestCase {
    private let valid = ["123", "iPhone 11", "http://apple.com/iphone11", "650.00", "cellular", "500"]

    func testValidRow() throws {
        let product = try Product(fields: valid)
        XCTAssertEqual(product.id, 123)
        XCTAssertEqual(product.name, "iPhone 11")
        XCTAssertEqual(product.price, 650)
        XCTAssertEqual(product.stock, 500)
    }

    func testWrongFieldCount() {
        XCTAssertThrowsError(try Product(fields: Array(valid.dropLast()))) { error in
            guard case Product.ValidationError.wrongFieldCount(5) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInvalidValues() {
        let cases: [(index: Int, value: String)] = [
            (0, "abc"), (0, "3000000000"),  // the id is a 32-bit CQL int
            (1, ""),
            (3, "free"), (3, "nan"), (3, "inf"),
            (5, "1.5"),
        ]
        for (index, value) in cases {
            var fields = valid
            fields[index] = value
            XCTAssertThrowsError(try Product(fields: fields), "\(Product.columns[index]) = \(value)") { error in
                guard case Product.ValidationError.invalidValue(let column, _) = error, column == Product.columns[index] else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testHeader() {
        XCTAssertNoThrow(try Product.validateHeader(Product.columns.map { $0.uppercased() }))
        XCTAssertThrowsError(try Product.validateHeader(Array(Product.columns.reversed())))
    }

    func testInsertStatementEscapesQuotes() throws {
        var fields = valid
        fields[1] = "Children's iPad case"
        let statement = try Product(fields: fields).insertStatement(into: "dynamic.c1")
        XCTAssertTrue(statement.contains("'Children''s iPad case'"), statement)
    }
}
