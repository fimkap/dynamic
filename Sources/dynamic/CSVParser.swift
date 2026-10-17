//
//  CSVParser.swift
//  dynamic
//
//  Created by Efim Polevoi on 03/08/2023.
//  Copyright © 2023 Efim Polevoi. All rights reserved.
//

import Foundation

let NUMBER_OF_FIELDS = 6

/// A `CSVParser` parses a csv file line and builds a query
///
class CSVParser {
    enum CSVLineError: Error {
        case invalidFormat
        case missingField(index: Int)
    }

    /// Parse a csv file line and build a query.
    ///
    /// - parameters:
    ///    - tableName: The name of the table to insert into.
    ///    - line: The row from csv file.
    /// - returns: A query to insert a row into the table.
    ///
    class func parseLine(_ tableName: String, _ line: String) throws -> String {
        // Separate components and discard leading/trailing whitespaces
        let product: [String] = line.components(separatedBy: ",").map { col in
            return col.trimmingCharacters(in: .whitespaces)
        }
        
        // Validate the number of fields in the CSV line
        guard product.count == NUMBER_OF_FIELDS else {
            throw CSVLineError.invalidFormat
        }
        
        // Validate and parse individual fields
        guard let productId = Int(product[0]),
              let productName = product[1].isEmpty ? nil : product[1],
              let productImageUrl = product[2].isEmpty ? nil : product[2],
              let productPrice = Float(product[3]),
              let productCategories = product[4].isEmpty ? nil : product[4],
              let productStock = Int(product[5]) else {
            throw CSVLineError.missingField(index: product.firstIndex(where: { $0.isEmpty }) ?? 0)
        }
        
        // Build the query
        let query = """
            INSERT INTO dynamic.c\(tableName)
            (product_id, product_name, product_image_url, product_price, product_categories, product_stock)
            VALUES (\(productId), '\(productName)', '\(productImageUrl)', \(productPrice), '\(productCategories)', \(productStock));
            """
        return query
    }
}
