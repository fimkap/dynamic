//
//  Product.swift
//  dynamic
//
//  Created by Efim Polevoi on 03/08/2023.
//  Copyright © 2023 Efim Polevoi. All rights reserved.
//

import Foundation

/// A `Product` is one row of the CSV file, validated and converted to the table's column types.
///
struct Product {
    /// The CSV columns, in order
    static let columns = ["product_id", "product_name", "product_image_url", "product_price", "product_categories", "product_stock"]

    enum ValidationError: Error, CustomStringConvertible {
        case unexpectedHeader([String])
        case wrongFieldCount(Int)
        case invalidValue(column: String, value: String)

        var description: String {
            switch self {
            case .unexpectedHeader(let fields):
                return "unexpected header \(fields.joined(separator: ", ")); expected \(Product.columns.joined(separator: ", "))"
            case .wrongFieldCount(let count):
                return "expected \(Product.columns.count) fields, found \(count)"
            case .invalidValue(let column, let value):
                return "invalid \(column) \"\(value)\""
            }
        }
    }

    let id: Int32
    let name: String
    let imageURL: String
    let price: Float
    let categories: String
    let stock: Int32

    /// Check that a header row names the expected columns, in order.
    ///
    static func validateHeader(_ fields: [String]) throws {
        guard fields.map({ $0.lowercased() }) == columns else {
            throw ValidationError.unexpectedHeader(fields)
        }
    }

    /// Validate a row and convert its fields.
    /// The table stores the id and the stock as CQL `int` and the price as `float`, all 32-bit,
    /// so values outside those ranges are rejected here rather than by Scylla.
    ///
    /// - parameters:
    ///    - fields: The row's fields, in the order of `columns`.
    ///
    init(fields: [String]) throws {
        guard fields.count == Product.columns.count else {
            throw ValidationError.wrongFieldCount(fields.count)
        }
        func required(_ index: Int) throws -> String {
            guard !fields[index].isEmpty else {
                throw ValidationError.invalidValue(column: Product.columns[index], value: fields[index])
            }
            return fields[index]
        }
        func parsed<T>(_ index: Int, _ parse: (String) -> T?) throws -> T {
            guard let value = parse(fields[index]) else {
                throw ValidationError.invalidValue(column: Product.columns[index], value: fields[index])
            }
            return value
        }
        id = try parsed(0) { Int32($0) }
        name = try required(1)
        imageURL = try required(2)
        price = try parsed(3) { Float($0).flatMap { $0.isFinite ? $0 : nil } }
        categories = try required(4)
        stock = try parsed(5) { Int32($0) }
    }

    /// Build the query to insert a product, with a `?` for each column's value
    ///
    /// - parameters:
    ///    - table: The table, qualified with its keyspace.
    ///
    static func insertQuery(into table: String) -> String {
        let markers = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        return "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(markers))"
    }

    /// The product's values, in the order of `columns`
    var values: [CQLValue] {
        return [.int(id), .text(name), .text(imageURL), .float(price), .text(categories), .int(stock)]
    }
}
