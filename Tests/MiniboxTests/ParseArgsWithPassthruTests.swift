// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

//
// Tests/MiniboxTests/ParseArgsWithPassthruTests.swift
// MiniboxSwift
//
// Version: 0.1.0
// Date: 2026-04-27
//

import Testing

private func parseArgs(withPassthru args: ArraySlice<String>) -> (
    opts: [String: String], flags: Set<String>, posArgs: [String], passthruArgs: [String]
) {
    var opts: [String: String] = [:]
    var flags = Set<String>()
    var posArgs: [String] = []
    var tail = args

    while let arg = tail.popFirst() {
        if arg == "--" {
            return (opts, flags, posArgs, Array(tail))
        } else if let match = arg.wholeMatch(of: /(--[^=]+)=(.*)/) {
            opts[String(match.output.1)] = String(match.output.2)
        } else if arg.hasPrefix("--") {
            if tail.first?.hasPrefix("--") == false {
                opts[arg] = tail.popFirst()
            } else {
                flags.insert(arg)
            }
        } else {
            posArgs.append(arg)
        }
    }

    return (opts, flags, posArgs, [])
}

struct ParseArgsWithPassthruTests {
    @Test
    func emptyArguments() {
        let (opts, flags, posArgs, passthruArgs) = parseArgs(withPassthru: [])
        #expect(opts.isEmpty)
        #expect(flags.isEmpty)
        #expect(posArgs.isEmpty)
        #expect(passthruArgs.isEmpty)
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
        let (opts, flags, posArgs, passthruArgs) = parseArgs(withPassthru: args[...])
        #expect(opts == expectedOpts)
        #expect(flags.isEmpty)
        #expect(posArgs.isEmpty)
        #expect(passthruArgs.isEmpty)
    }

    @Test(
        "Test with valid flags",
        arguments: [
            (["--force"], Set(["--force"])),
            (["--force", "--force"], Set(["--force"])),
            (["--force", "--no-force", "--force"], Set(["--force", "--no-force"])),
            (
                ["--force", "--no-force", "--force", "--no-force"],
                Set(["--force", "--no-force"])
            ),
            (
                ["--force", "--no-force", "--force", "--no-force", "--force"],
                Set(["--force", "--no-force"])
            ),
        ]
    )
    func flags(args: [String], expectedFlags: Set<String>) {
        let (opts, flags, posArgs, passthruArgs) = parseArgs(withPassthru: args[...])
        #expect(opts.isEmpty)
        #expect(flags == expectedFlags)
        #expect(posArgs.isEmpty)
        #expect(passthruArgs.isEmpty)
    }

    @Test(
        "Test with valid posArgs and passthruArgs",
        arguments: [
            (["a"], ["a"], []),
            (["a", "b"], ["a", "b"], []),
            (["--", "a", "b", "c"], [], ["a", "b", "c"]),
            (["a", "--", "b", "c"], ["a"], ["b", "c"]),
            (["a", "b", "--", "c", "d"], ["a", "b"], ["c", "d"]),
        ]
    )
    func posArgs(args: [String], expectedPosArgs: [String], expectedPassthruArgs: [String]) {
        let (opts, flags, posArgs, passthruArgs) = parseArgs(withPassthru: args[...])
        #expect(opts.isEmpty)
        #expect(flags.isEmpty)
        #expect(posArgs == expectedPosArgs)
        #expect(passthruArgs == expectedPassthruArgs)
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
            "--f": "-g",
        ]
        let expectedFlags = Set([
            "--d",
            "--e",
            "--i",
        ])
        let expectedPosArgs = [
            "-a",
            "-h",
        ]
        let expectedPassthruArgs = [
            "--j",
            "-l",
        ]
        let (opts, flags, posArgs, passthruArgs) = parseArgs(withPassthru: args[...])
        #expect(opts == expectedOpts)
        #expect(flags == expectedFlags)
        #expect(posArgs == expectedPosArgs)
        #expect(passthruArgs == expectedPassthruArgs)
    }
}
