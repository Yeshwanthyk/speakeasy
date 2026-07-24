// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Speakeasy",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "Speakeasy", targets: ["Speakeasy"])
    ],
    targets: [
        .target(
            name: "Speakeasy",
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
            name: "SpeakeasyTests",
            dependencies: ["Speakeasy"],
            path: "Tests"
        )
    ]
)
