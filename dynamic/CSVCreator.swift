//
//  CSVCreator.swift
//  dynamic
//
//  Created by Efim Polevoi on 08/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation

class CSVCreator {

    class func load(_ filePath: String, linesCount: Int) throws {
        let dir = "/Users/fimkap/dev/dynamic/" + filePath
        let fileURL = URL(fileURLWithPath: dir)
        /* if let dir = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first { */
        //let fileURL = dir.appendingPathComponent(filePath)
        /* var text = "32,iPhone" */
        
        /* var product = [ */
        /*     "product_id": 1, */
        /*     "product_name": "iPhone11", */
        /*     "product_image_url": "http://apple.com/iphone11", */
        /*     "product_price": 650.0, */
        /*     "product_categories": "cellular", */
        /*     "product_stock": 400] as [String : Any] */

        let text = ",iPhone11,http://apple.com/iphone11,650.00,cellular,500\n"
        var records = ""
        
        for id in 1...linesCount {
            /* product["product_id"] = id */
            /* text = (product.compactMap({ (key, value) -> String in */
            /*     return "\(value)" */
            /* }) as Array).joined(separator: ",") */
            records += String(id) + text
        }
        do {
            try records.write(to: fileURL, atomically: false, encoding: .utf8)
        }
        catch {
            print("error: \(error)")
        }

        
        //}
    }
}
