//
//  CSVCreator.swift
//  dynamic
//
//  Created by Efim Polevoi on 08/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation

let BATCH_SIZE = 1000

/// A `CSVCreator` is the way to create a test csv file for `dynamic`.
/// It gets a file path and lines count and creates a csv file.
/// Some product names hold commas, quotes and apostrophes, so loading the file
/// exercises CSV quoting and the escaping of values in queries.
///
class CSVCreator {
    
    enum CSVCreatorError: Error {
        case fileOpenFailed
    }

    /// The products the file cycles through
    static let samples: [(name: String, imageURL: String, price: Float, categories: String)] = [
        ("iPhone 11", "http://apple.com/iphone11", 650.00, "cellular"),
        ("iPad mini", "http://apple.com/ipadmini", 450.00, "tablet"),
        ("MacBook Pro 14\", M3", "http://apple.com/macbookpro", 1999.00, "laptop"),
        ("Apple Watch, Series 9", "http://apple.com/watch", 399.00, "wearable"),
        ("AirPods \"Pro\"", "http://apple.com/airpods", 249.00, "audio"),
        ("Children's iPad case", "http://example.com/ipadcase", 29.90, "accessory"),
    ]
    
    /// Create a CSV file and load it with the test data
    ///
    /// - parameters:
    ///    - filePath: The file path to create a CSV file on.
    ///    - totalLines: The lines count in a CSV file
    ///
    class func load(_ filePath: String, totalLines: Int) throws {
        guard FileManager.default.createFile(atPath: filePath, contents: nil),
              let file = FileHandle(forWritingAtPath: filePath) else {
            throw CSVCreatorError.fileOpenFailed
        }
        defer { try? file.close() }

        // Write the header
        try file.write(contentsOf: Data((Product.columns.joined(separator: ",") + "\n").utf8))

        // Write data in batches
        var id = 1
        while id <= totalLines {
            var batch = ""
            for _ in 0..<min(BATCH_SIZE, totalLines - id + 1) {
                batch += row(id: id)
                id += 1
            }
            try file.write(contentsOf: Data(batch.utf8))
        }
    }

    /// Build the CSV line for a product
    ///
    /// - parameters:
    ///    - id: The product id; it picks the sample and the stock count.
    ///
    static func row(id: Int) -> String {
        let sample = samples[(id - 1) % samples.count]
        let fields = [
            String(id),
            sample.name,
            sample.imageURL,
            String(format: "%.2f", sample.price),
            sample.categories,
            String(id * 7 % 1000),
        ]
        return fields.map(quoted).joined(separator: ",") + "\n"
    }

    /// Quote a field if it holds a comma, a quote, a line break or surrounding whitespace,
    /// writing each quote inside it twice (RFC 4180)
    ///
    static func quoted(_ field: String) -> String {
        let special: Set<UInt8> = [UInt8(ascii: ","), UInt8(ascii: "\""), UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        let needsQuotes = field.utf8.contains(where: special.contains)
            || field.first?.isWhitespace == true
            || field.last?.isWhitespace == true
        guard needsQuotes else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
