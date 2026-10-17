//
//  CSVReader.swift
//  dynamic
//
//  Created by Efim Polevoi on 17/10/2026.
//  Copyright © 2026 Efim Polevoi. All rights reserved.
//

import Foundation

/// A `CSVReader` reads a CSV file one record at a time, following RFC 4180:
/// a field in double quotes may hold commas, line breaks, and quotes written as `""`.
/// Whitespace around a field is ignored, as in `123, iPhone11, ...`; inside quotes it is kept.
///
/// The file is read in chunks, so memory use doesn't grow with the file size.
///
/// The most basic usage of a `CSVReader` is
///
///     let reader = try CSVReader(path: filePath)
///     while let fields = try reader.next() { ... }
///
final class CSVReader {
    enum CSVError: Error, CustomStringConvertible {
        case cannotOpen(path: String)
        case unterminatedQuote(line: Int)
        case textAfterClosingQuote(line: Int)

        var description: String {
            switch self {
            case .cannotOpen(let path):
                return "cannot open \(path)"
            case .unterminatedQuote(let line):
                return "line \(line): a quoted field is never closed"
            case .textAfterClosingQuote(let line):
                return "line \(line): unexpected text after a closing quote"
            }
        }
    }

    /// Where the parser is within a record
    private enum State {
        case fieldStart     // before a field, skipping whitespace
        case unquoted       // in a field without quotes
        case quoted         // in a quoted field
        case quoteInQuoted  // just read a quote in a quoted field: half of "" or the closing quote
        case afterQuoted    // after a closing quote, skipping whitespace
    }

    /// The line where the record most recently returned by `next()` starts, counting from 1
    private(set) var recordLine = 0

    private let readChunk: () throws -> [UInt8]
    private var buffer: [UInt8] = []
    private var index = 0
    private var line = 1
    private var started = false

    /// Read a CSV file.
    ///
    /// - parameters:
    ///    - path: The file path.
    ///    - chunkSize: How many bytes to read at a time.
    ///
    init(path: String, chunkSize: Int = 64 * 1024) throws {
        guard let file = FileHandle(forReadingAtPath: path) else {
            throw CSVError.cannotOpen(path: path)
        }
        self.readChunk = {
            return [UInt8](try file.read(upToCount: chunkSize) ?? Data())
        }
    }

    /// Read CSV text held in memory.
    ///
    /// - parameters:
    ///    - text: The CSV text.
    ///    - chunkSize: How many bytes to hand over at a time. Tests use small sizes so that
    ///      records and multi-byte characters get split across chunks.
    ///
    init(text: String, chunkSize: Int = 64 * 1024) {
        let bytes = Array(text.utf8)
        var offset = 0
        self.readChunk = {
            let end = min(offset + chunkSize, bytes.count)
            defer { offset = end }
            return Array(bytes[offset..<end])
        }
    }

    /// Read the next record.
    /// A malformed record throws, and the next call continues from the following line.
    ///
    /// - returns: The record's fields, or `nil` at the end of the file.
    ///
    func next() throws -> [String]? {
        if !started {
            try skipByteOrderMark()
        }
        var fields: [String] = []
        var field: [UInt8] = []
        var state = State.fieldStart
        recordLine = line

        func endField() {
            if state == .unquoted {
                // Drop trailing whitespace, including the CR of a CRLF line ending
                while let last = field.last, last == ASCII.space || last == ASCII.tab || last == ASCII.cr {
                    field.removeLast()
                }
            }
            fields.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }

        while let byte = try nextByte() {
            switch state {
            case .fieldStart:
                switch byte {
                case ASCII.space, ASCII.tab, ASCII.cr:
                    continue
                case ASCII.quote:
                    state = .quoted
                case ASCII.comma:
                    endField()
                case ASCII.lf:
                    line += 1
                    if fields.isEmpty {
                        recordLine = line  // a blank line, skipped
                        continue
                    }
                    endField()  // an empty last field, after a trailing comma
                    return fields
                default:
                    field.append(byte)
                    state = .unquoted
                }
            case .unquoted:
                switch byte {
                case ASCII.comma:
                    endField()
                    state = .fieldStart
                case ASCII.lf:
                    line += 1
                    endField()
                    return fields
                default:
                    field.append(byte)
                }
            case .quoted:
                if byte == ASCII.quote {
                    state = .quoteInQuoted
                } else {
                    if byte == ASCII.lf {
                        line += 1
                    }
                    field.append(byte)
                }
            case .quoteInQuoted, .afterQuoted:
                switch byte {
                case ASCII.quote where state == .quoteInQuoted:
                    field.append(byte)
                    state = .quoted
                case ASCII.space, ASCII.tab, ASCII.cr:
                    state = .afterQuoted
                case ASCII.comma:
                    endField()
                    state = .fieldStart
                case ASCII.lf:
                    line += 1
                    endField()
                    return fields
                default:
                    try skipLine()
                    throw CSVError.textAfterClosingQuote(line: recordLine)
                }
            }
        }

        // The end of the file
        switch state {
        case .fieldStart where fields.isEmpty:
            return nil
        case .quoted:
            throw CSVError.unterminatedQuote(line: recordLine)
        default:
            endField()
            return fields
        }
    }

    private func nextByte() throws -> UInt8? {
        if index == buffer.count {
            buffer = try readChunk()
            index = 0
            if buffer.isEmpty {
                return nil
            }
        }
        let byte = buffer[index]
        index += 1
        return byte
    }

    /// Skip a UTF-8 byte order mark, which some tools write at the start of a file
    ///
    private func skipByteOrderMark() throws {
        started = true
        while buffer.count < 3 {
            let chunk = try readChunk()
            if chunk.isEmpty {
                break
            }
            buffer += chunk
        }
        if buffer.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
    }

    /// Skip to the start of the next line, after a malformed record
    ///
    private func skipLine() throws {
        while let byte = try nextByte() {
            if byte == ASCII.lf {
                line += 1
                return
            }
        }
    }
}

/// The bytes the parser looks for. In UTF-8 they never occur inside a multi-byte character,
/// so the parser can scan bytes and decode each field once it is complete.
///
private enum ASCII {
    static let tab = UInt8(ascii: "\t")
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let quote = UInt8(ascii: "\"")
    static let comma = UInt8(ascii: ",")
}
