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

    func testInsertQueryHasAMarkerPerColumn() {
        XCTAssertEqual(
            Product.insertQuery(into: "dynamic.c1"),
            "INSERT INTO dynamic.c1 (product_id, product_name, product_image_url, product_price, product_categories, product_stock) VALUES (?, ?, ?, ?, ?, ?)")
    }

    func testValuesFollowColumns() throws {
        var fields = valid
        fields[1] = "Children's iPad case"
        XCTAssertEqual(
            try Product(fields: fields).values,
            [.int(123), .text("Children's iPad case"), .text("http://apple.com/iphone11"), .float(650), .text("cellular"), .int(500)])
    }
}
