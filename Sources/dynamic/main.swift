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
/// It exits with 0 when every row was written, and with 1 on an error,
/// or when some rows failed or were skipped as invalid.
///

let MAX_LINES = 1_000_000
let USAGE = """
    Usage:
     load into Scylla DB from csv file
     dynamic [--in-flight <writes>] [--connections <count>] <customer_id>.csv
     create csv file
     dynamic <customer_id>.csv <lines>

    Options:
     --in-flight <writes>    most writes outstanding at a time (default \(MAX_WRITES_IN_FLIGHT))
     --connections <count>   connections to Scylla (default \(CONNECTION_COUNT))
    """

/// Print an error to standard error and exit with status 1
///
func fail(_ message: String) -> Never {
    printError(message)
    exit(EXIT_FAILURE)
}

// Separate the options from the file name and lines count
var maxWritesInFlight = MAX_WRITES_IN_FLIGHT
var connectionCount = CONNECTION_COUNT
var arguments: [String] = []
var remaining = CommandLine.arguments.dropFirst()
while let argument = remaining.popFirst() {
    switch argument {
    case "--in-flight", "--connections":
        guard let value = remaining.popFirst().flatMap({ Int($0) }), value > 0 else {
            fail("\(argument) needs a positive number")
        }
        if argument == "--in-flight" {
            maxWritesInFlight = value
        } else {
            connectionCount = value
        }
    default:
        arguments.append(argument)
    }
}

guard arguments.count == 1 || arguments.count == 2 else {
    print(USAGE)
    exit(EXIT_FAILURE)
}

let filePath = arguments[0]

if arguments.count == 1 {
    // Check if the file exists at the specified filePath
    guard FileManager.default.fileExists(atPath: filePath) else {
        fail("file not found: \(filePath)")
    }
    // We derive a table name from the file name, which carries the customer id: 232.csv -> c232
    let tableName = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
    guard !tableName.isEmpty, tableName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
        fail("the file name should be a customer id: letters, digits and underscores only")
    }

    // Create keyspace and customer table. Dispatch writes.
    do {
        // Read the csv file record by record not to load the whole file into memory.
        // Check the header before connecting, so a wrong file fails fast.
        let reader = try CSVReader(path: filePath)
        guard let header = try reader.next() else {
            fail("the file is empty")
        }
        try Product.validateHeader(header)

        let loader = Loader(tableName: tableName, connections: connectionCount, maxWritesInFlight: maxWritesInFlight)
        loader.setup()
        try loader.initKeyspace()
        let complete = try loader.dispatchQueries(reader)
        try loader.shutdown()
        exit(complete ? EXIT_SUCCESS : EXIT_FAILURE)
    } catch {
        fail("\(error)")
    }
}

if arguments.count == 2 {
    // Create csv file with the given lines count
    guard let linesCount = Int(arguments[1]), linesCount > 0 && linesCount <= MAX_LINES else {
        fail("the lines count should be a number from 1 to \(MAX_LINES)")
    }
    do {
        try CSVCreator.load(filePath, totalLines: linesCount)
    } catch {
        fail("\(error)")
    }
}
