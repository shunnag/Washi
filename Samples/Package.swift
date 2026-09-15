// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WashiSamples",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AppKitReader", targets: ["AppKitReader"]),
        .executable(name: "SwiftUIReader", targets: ["SwiftUIReader"]),
    ],
    dependencies: [.package(path: "..")],
    targets: [
        .target(
            name: "ReaderSampleSupport",
            dependencies: [.product(name: "Washi", package: "Washi")],
            resources: [.copy("Resources/Demo.epub")]
        ),
        .executableTarget(name: "AppKitReader", dependencies: ["ReaderSampleSupport"]),
        .executableTarget(name: "SwiftUIReader", dependencies: ["ReaderSampleSupport"]),
        .testTarget(name: "ReaderSampleSupportTests", dependencies: ["ReaderSampleSupport"]),
    ]
)
