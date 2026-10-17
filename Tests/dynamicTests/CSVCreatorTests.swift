import XCTest
@testable import dynamic

final class CSVCreatorTests: XCTestCase {
    /// A generated file reads back as the same products, commas, quotes and apostrophes included.
    func testGeneratedFileReadsBack() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("CSVCreatorTests-\(UUID().uuidString).csv").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let count = 2 * CSVCreator.samples.count + 1
        try CSVCreator.load(path, totalLines: count)

        let reader = try CSVReader(path: path)
        try Product.validateHeader(XCTUnwrap(reader.next()))
        var products: [Product] = []
        while let fields = try reader.next() {
            products.append(try Product(fields: fields))
        }
        XCTAssertEqual(products.map(\.id), Array(1...Int32(count)))
        for product in products {
            let sample = CSVCreator.samples[Int(product.id - 1) % CSVCreator.samples.count]
            XCTAssertEqual(product.name, sample.name)
            XCTAssertEqual(product.imageURL, sample.imageURL)
            XCTAssertEqual(product.price, sample.price)
        }
    }
}
