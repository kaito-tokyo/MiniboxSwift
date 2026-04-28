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
        .executable(name: "minibox-view", targets: ["MiniboxView"]),
        .executable(name: "minibox-run", targets: ["MiniboxRun"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1")
    ],
    targets: [
        .executableTarget(
            name: "MiniboxCreateBaseMacOS",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(name: "MiniboxView"),
        .executableTarget(name: "MiniboxRun"),
        .testTarget(name: "MiniboxTests"),
    ],
    swiftLanguageModes: [.v6]
)
