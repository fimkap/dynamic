//
//  main.swift
//  dynamic
//
//  Created by Efim Polevoi on 06/02/2020.
//  Copyright © 2020 Efim Polevoi. All rights reserved.
//

import Foundation

/// A `main` is the entry point of `dynamic`.
/// It reads command line arguments and writes csv content into Scylla DB or
///  creates csv file with a specified lines count.
///

let MAX_LINES = 1_000_000
let argc = CommandLine.argc

if argc < 2 || argc > 3 {
    print("Usage:\n load into Scylla DB from csv file\n dynamic <filename>\n create csv file\n dynamic <filename> <lines>")
    exit(0)
}

let filePath = CommandLine.arguments[1]

if argc == 2 {
    // Create keyspace and customer table. Dispatch writes.
    do {
        let driver = ScyllaDriver()
        driver.setup()
        let firstDot = filePath.firstIndex(of: ".") ?? filePath.endIndex
        let tableName = String(filePath[..<firstDot])
        try driver.initKeyspace(tableName)
        try driver.dispatchQueries(filePath, tableName)
        try driver.shutdown()
    } catch {
        print("error: \(error)")
    }
}

if argc == 3 {
    // Create csv file with the given lines count
    do {
        // Parse the command-line argument into an integer
        if let linesCount = Int(CommandLine.arguments[2]) {
            // Check for valid lines count
            guard linesCount > 0 && linesCount <= MAX_LINES else {
                print("error: Invalid lines count. It should be between 1 and 1,000,000.")
                exit(0)
            }
            // If the lines count is valid, load the CSVCreator
            try CSVCreator.load(filePath, linesCount: linesCount)
        } else {
            print("error: Invalid lines count. Please provide a valid integer value.")
        }
    } catch {
        print("error: \(error)")
    }
}
