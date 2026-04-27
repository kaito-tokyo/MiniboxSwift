// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

//
// Tests/MiniboxTests/ParseArgsTests.swift
// MiniboxSwift
//
// Version: 0.1.0
// Date: 2026-04-27
//

import Testing

private func parseArgs(_ args: ArraySlice<String>) -> ([String: String], [String]) {
    var opts: [String: String] = [:]
    var posArgs: [String] = []
    var tail = args

    while let arg = tail.popFirst() {
        if arg == "--" {
            posArgs.append(contentsOf: tail)
            break
        } else if let match = arg.wholeMatch(of: /(--[^=]+)=(.*)/) {
            opts[String(match.output.1)] = String(match.output.2)
        } else if arg.hasPrefix("--") {
            if let optarg = tail.first, !optarg.hasPrefix("--") {
                opts[arg] = optarg
                _ = tail.popFirst()
            } else {
                opts[arg] = "true"
            }
        } else {
            posArgs.append(arg)
        }
    }

    return (opts, posArgs)
}

struct ParseArgsTests {
    @Test
    func emptyArguments() {
        let (opts, posArgs) = parseArgs([])
        #expect(opts.isEmpty)
        #expect(posArgs.isEmpty)
    }

    @Test
    func checkForFlag() {
        let (opts, _) = parseArgs(["--force"])
        #expect(opts["--force"] == "true")
    }

    @Test(
        "Test with valid flags",
        arguments: [
            (["--force"], ["--force": "true"]),
            (["--force", "--force"], ["--force": "true"]),
            (["--force", "--no-force", "--force"], ["--force": "true", "--no-force": "true"]),
            (
                ["--force", "--no-force", "--force", "--no-force"],
                ["--force": "true", "--no-force": "true"]
            ),
            (
                ["--force", "--no-force", "--force", "--no-force", "--force"],
                ["--force": "true", "--no-force": "true"]
            ),
        ]
    )
    func flags(args: [String], expectedOpts: [String: String]) {
        let (opts, posArgs) = parseArgs(args[...])
        #expect(opts == expectedOpts)
        #expect(posArgs.isEmpty)
    }

    @Test(
        "Test with valid options",
        arguments: [
            (["--path1", "/tmp/path1"], ["--path1": "/tmp/path1"]),
            (["--path1=/tmp/path1"], ["--path1": "/tmp/path1"]),
            (["--path1=/tmp/path1", "--path1=/tmp/path1"], ["--path1": "/tmp/path1"]),
            (["--path1=/tmp/path1", "--path1=/tmp/path2"], ["--path1": "/tmp/path2"]),
            (
                ["--path1=/tmp/path1", "--path2=/tmp/path2"],
                ["--path1": "/tmp/path1", "--path2": "/tmp/path2"]
            ),
            (
                ["--path1=/tmp/path1", "--path2=/tmp/path2", "--path1=/tmp/path3"],
                ["--path1": "/tmp/path3", "--path2": "/tmp/path2"]
            ),
            (
                ["--path1=/tmp/path1", "--path1=/tmp/path2", "--path1=/tmp/path3"],
                ["--path1": "/tmp/path3"]
            ),
        ]
    )
    func options(args: [String], expectedOpts: [String: String]) {
        let (opts, posArgs) = parseArgs(args[...])
        #expect(opts == expectedOpts)
        #expect(posArgs.isEmpty)
    }

    @Test(
        "Test with valid posArgs",
        arguments: [
            (["a"], ["a"]),
            (["a", "b"], ["a", "b"]),
            (["--", "a", "b", "c"], ["a", "b", "c"]),
            (["a", "--", "b", "c"], ["a", "b", "c"]),
            (["a", "b", "--", "c", "d"], ["a", "b", "c", "d"]),
        ]
    )
    func posArgs(args: [String], expectedPosArgs: [String]) {
        let (opts, posArgs) = parseArgs(args[...])
        #expect(opts.isEmpty)
        #expect(posArgs == expectedPosArgs)
    }

    @Test
    func mixedArgs() {
        let args = [
            "-a",
            "--b=c",
            "--d",
            "--e",
            "--f",
            "-g",
            "-h",
            "--i",
            "--b",
            "z",
            "--",
            "--j",
            "-l",
        ]
        let expectedOpts = [
            "--b": "z",
            "--d": "true",
            "--e": "true",
            "--f": "-g",
            "--i": "true",
        ]
        let expectedPosArgs = [
            "-a",
            "-h",
            "--j",
            "-l",
        ]
        let (opts, posArgs) = parseArgs(args[...])
        #expect(opts == expectedOpts)
        #expect(posArgs == expectedPosArgs)
    }
}
