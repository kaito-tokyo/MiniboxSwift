// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

//
// Tests/MiniboxTests/LogStderrTests.swift
// MiniboxSwift
//
// Version: 0.1.0
// Date: 2026-04-27
//

import Foundation
import Testing
import os

private func logStderr(
    level: OSLogType, _ message: String, fileHandle: FileHandle = FileHandle.standardError
) {
    let logMessage =
        switch level {
        case .debug: "DEBUG: \(message)\n"
        case .default: "\(message)\n"
        case .error: "ERROR: \(message)\n"
        case .fault: "FAULT: \(message)\n"
        case .info: "INFO: \(message)\n"
        default: "UNKNOWN: \(message)\n"
        }
    try? fileHandle.write(contentsOf: Data(logMessage.utf8))
}

struct LogStderrTests {
    @Test(
        "Test for each log level",
        arguments: [
            (OSLogType.debug, "DEBUG: message"),
            (OSLogType.default, "message"),
            (OSLogType.error, "ERROR: message"),
            (OSLogType.fault, "FAULT: message"),
            (OSLogType.info, "INFO: message"),
        ])
    func test(level: OSLogType, expected: String) async throws {
        let pipe = Pipe()

        let writer = pipe.fileHandleForWriting
        logStderr(level: level, "message", fileHandle: writer)
        try writer.close()

        let reader = pipe.fileHandleForReading
        let data = try #require(try reader.readToEnd())
        let actualLogMessage = String(data: data, encoding: .utf8)

        #expect(actualLogMessage == "\(expected)\n")
    }
}
