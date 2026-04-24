// swift-tools-version: 6.3

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "MiniboxSwift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "minibox-run", targets: ["MiniboxRun"])
    ],
    targets: [
        .executableTarget(name: "MiniboxRun")
    ],
    swiftLanguageModes: [.v6]
)
