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
            path: "Sources/diskstat",
            // Make the compiler enforce that the app's mutable state is only
            // touched from the main thread, instead of it being a convention
            // nothing checks. This is what makes `@MainActor` on the classes
            // worth anything.
            //
            // `unsafeFlags` means this package cannot be used as a dependency.
            // That is fine for an app; if that ever matters, the supported route
            // is `swift-tools-version: 6.0`, which enables the Swift 6 language
            // mode and turns the remaining warnings into errors.
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
        // The cleaner deletes files, so its safety guarantees are pinned down by
        // tests rather than by review. Run with `swift test`.
        .testTarget(
            name: "DiskStatTests",
            dependencies: ["diskstat"]
        )
    ]
)
