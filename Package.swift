// swift-tools-version: 6.0
import Foundation
import PackageDescription

// TDLib 1.8.0 from Homebrew predates the API used here (inline setTdlibParameters, draft content types),
// so the copy built into vendor/tdlib wins unless TDLIB_PREFIX says otherwise.
let vendoredTDLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("vendor/tdlib").path
let tdlibPrefix = ProcessInfo.processInfo.environment["TDLIB_PREFIX"]
    ?? (FileManager.default.fileExists(atPath: vendoredTDLib + "/lib/libtdjson.dylib") ? vendoredTDLib : "/opt/homebrew/opt/tdlib")

let package = Package(
    name: "SwiftLite",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Animated (.tgs) stickers are Lottie animations. lottie-spm is Airbnb's prebuilt XCFramework of lottie-ios.
        .package(url: "https://github.com/airbnb/lottie-spm.git", exact: "4.6.1")
    ],
    targets: [
        .systemLibrary(name: "CTDLib", path: "Sources/CTDLib"),
        .executableTarget(
            name: "SwiftLite",
            dependencies: ["CTDLib", .product(name: "Lottie", package: "lottie-spm")],
            path: "Sources/SwiftLite",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I\(tdlibPrefix)/include"]),
                .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release))
            ],
            linkerSettings: [
                // Without a direct reference AVKit is not linked, and the first video player crashes looking up
                // its AppKit superclass.
                .linkedFramework("AVKit"),
                .linkedFramework("WebKit"),
                // The rpath lets `swift run` find an @rpath-installed libtdjson; build.sh swaps it for the bundle.
                .unsafeFlags(["-L\(tdlibPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(tdlibPrefix)/lib"])
            ]
        )
    ]
)
