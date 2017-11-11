// swift-tools-version:4.0

import PackageDescription

let package = Package(
    name: "Unused",
    dependencies: [
        .package(url: "git@github.com:jpsim/SourceKitten.git", from: "0.18.1"),
        .package(url: "https://github.com/RLovelett/swift-package-manager.git", .exact("4.0.0-beta.2")),
        .package(url: "git@github.com:JohnSundell/Files.git", from: "2.0.0")
    ],
    targets: [
        .target(
          name: "Unused",
          dependencies: [
            "SourceKittenFramework",
            "Files",
            "UnusedCore",
            "SwiftPM"
          ]
        ),
        .target(
          name: "UnusedCore"
        )
    ]
)
