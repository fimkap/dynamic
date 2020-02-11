//
//  CSVCreator.swift
//  dynamic
//
//  Created by Efim Polevoi on 08/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation

/// A `CSVCreator` is the way to create a test csv file for `dynamic`.
/// It gets a file name and lines count and creates a csv file in the current dir
///
class CSVCreator {

    class func load(_ filePath: String, linesCount: Int) throws {
        let fileURL = URL(fileURLWithPath: "./" + filePath)
        let text = ",iPhone11,http://apple.com/iphone11,650.00,cellular,500\n"
        var records = "product_id, product_name, product_image_url,  product_price, product_categories, product_stock \n"
   
        // Increment index for each row
        for id in 1...linesCount {
            records += String(id) + text
        }
        do {
            try records.write(to: fileURL, atomically: false, encoding: .utf8)
        }
        catch {
            print("error: \(error)")
        }
    }
}
