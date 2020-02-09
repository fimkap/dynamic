//
//  main.swift
//  dynamic
//
//  Created by Efim Polevoi on 06/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation
import ScyllaKit

let argc = CommandLine.argc
if argc < 2 {
    print("Usage: ")
} else {
    errno = 0
    let filePath = CommandLine.arguments[1]

    if argc == 3 {
        // Create csv file with provided number of lines
        let numberLines = Int(CommandLine.arguments[2]) ?? 0
        //let csvCreator = CSVCreator()
        try CSVCreator.load(filePath, numberLines: numberLines)
    } else {

      do {
          let driver = ScyllaDriver()
          driver.setup()
          try driver.initKeyspace()
          try driver.dispatchQueries(filePath)
          try driver.shutdown()
      } catch {
          print("error: \(error)")
      }
    }
}

/* print("argc: \(argc) arguments: \(CommandLine.arguments)") */
