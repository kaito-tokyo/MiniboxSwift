// swift-tools-version: 6.3

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "MiniboxSwift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "minibox-create-base-macos", targets: ["MiniboxCreateBaseMacOS"]),
        .executable(name: "minibox-run", targets: ["MiniboxRun"]),
        .executable(name: "minibox-tools-linux-exec", targets: ["MiniboxToolsLinuxExec"]),
        .executable(name: "minibox-view", targets: ["MiniboxView"]),
    ],
    targets: [
        .executableTarget(name: "MiniboxCreateBaseMacOS"),
        .executableTarget(name: "MiniboxRun"),
        .executableTarget(name: "MiniboxToolsLinuxExec"),
        .executableTarget(name: "MiniboxView"),
        .testTarget(name: "MiniboxTests"),
    ],
    swiftLanguageModes: [.v6]
)
