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
    if freopen(filePath, "r", stdin) == nil {
        perror(filePath)
    } else {
        while let line = readLine() {
            print(line)
        }
    }
}

do {
    let driver = ScyllaDriver()
    driver.setup()
    try driver.doQuery()
    try driver.shutdown()
} catch {
    print("error: \(error)")
}

/* print("argc: \(argc) arguments: \(CommandLine.arguments)") */
