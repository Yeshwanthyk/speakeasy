// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "Wisp", targets: ["Wisp"])
    ],
    targets: [
        .target(
            name: "Wisp",
            path: "Sources",
            exclude: [
                "AppDelegate.swift",
                "ParakeetTranscriber.swift",
                "main.swift"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .testTarget(
            name: "WispTests",
            dependencies: ["Wisp"],
            path: "Tests"
        )
    ]
)
