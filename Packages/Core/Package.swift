// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "Core", targets: ["Core"])
    ],
    dependencies: [
        // Spotify iOS SDK — ships as an SPM package with a pre-configured
        // .binaryTarget pointing at SpotifyiOS.xcframework inside the repo.
        // Gives us SPTAppRemote for full-track playback via the installed
        // Spotify app (Premium users only).
        .package(url: "https://github.com/spotify/ios-sdk.git", from: "5.0.1")
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "SpotifyiOS", package: "ios-sdk")
            ],
            path: "Sources/Core",
            resources: [
                .process("Rendering/Shaders")
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        )
    ]
)
