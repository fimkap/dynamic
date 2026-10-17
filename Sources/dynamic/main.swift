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
    // Check if the file exists at the specified filePath
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: filePath) else {
        print("File not found at the specified path.")
        exit(0)
    }
    // We derive a table name from the file name, which carries the customer id: 232.csv -> c232
    let tableName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
    guard !tableName.isEmpty, tableName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
        print("The file name should be a customer id: letters, digits and underscores only.")
        exit(0)
    }
    
    // Create keyspace and customer table. Dispatch writes.
    do {
        // Read the csv file record by record not to load the whole file into memory.
        // Check the header before connecting, so a wrong file fails fast.
        let reader = try CSVReader(path: filePath)
        guard let header = try reader.next() else {
            print("The file is empty.")
            exit(0)
        }
        try Product.validateHeader(header)

        let driver = ScyllaDriver(tableName: tableName)
        driver.setup()
        try driver.initKeyspace()
        try driver.dispatchQueries(reader)
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
            try CSVCreator.load(filePath, totalLines: linesCount)
        } else {
            print("error: Invalid lines count. Please provide a valid integer value.")
        }
    } catch {
        print("error: \(error)")
    }
}
