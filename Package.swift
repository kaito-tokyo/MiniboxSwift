// swift-tools-version: 6.3

// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "MiniboxSwift",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "minibox-run", targets: ["MiniboxRun"]),
    .executable(name: "minibox-create-base", targets: ["MiniboxCreateBase"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      from: "1.7.1"
    )
  ],
  targets: [
    .executableTarget(name: "MiniboxRun"),
    .executableTarget(
      name: "MiniboxCreateBase",
      dependencies: [
        .product(
          name: "ArgumentParser",
          package: "swift-argument-parser"
        )
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
