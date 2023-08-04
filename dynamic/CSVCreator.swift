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
/// It gets a file name and lines count and creates a csv file in the current dir
///
class CSVCreator {
    
    enum CSVCreatorError: Error {
        case fileOpenFailed
    }
    
    /// Create a CSV file and load it with the test data
    ///
    /// - parameters:
    ///    - filePath: The file path to create a CSV file on.
    ///    - totalLines: The lines count in a CSV file
    ///
    class func load(_ filePath: String, totalLines: Int) throws {
        let fileURL = URL(fileURLWithPath: "./" + filePath)
        let text = ",iPhone11,http://apple.com/iphone11,650.00,cellular,500\n"
        let header = "product_id, product_name, product_image_url, product_price, product_categories, product_stock \n"
        
        guard let outputStream = OutputStream(url: fileURL, append: false) else {
            throw CSVCreatorError.fileOpenFailed
        }
        outputStream.open()
        
        // Write the header
        if let headerData = header.data(using: .utf8) {
            headerData.withUnsafeBytes { buffer in
                _ = outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: headerData.count)
            }
        }
        
        // Write data in batches
        var remainingLines = totalLines
        var id = 1
        
        while remainingLines > 0 {
            let batchLines = min(BATCH_SIZE, remainingLines)
            var batchData = ""
            
            for _ in 1...batchLines {
                batchData += "\(id)\(text)"
                id += 1
            }
            
            if let batchData = batchData.data(using: .utf8) {
                batchData.withUnsafeBytes { buffer in
                    _ = outputStream.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: batchData.count)
                }
            }
            
            remainingLines -= batchLines
        }
        
        outputStream.close()
    }
}
