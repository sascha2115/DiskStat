// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "diskstat",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "diskstat", targets: ["diskstat"])
    ],
    targets: [
        .executableTarget(
            name: "diskstat",
            path: "Sources/diskstat"
        )
    ]
)
