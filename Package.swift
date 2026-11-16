// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "DPS150",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DPS150Kit"),
        .executableTarget(name: "DPS150Control", dependencies: ["DPS150Kit"]),
        .testTarget(name: "DPS150KitTests", dependencies: ["DPS150Kit"]),
    ]
)
