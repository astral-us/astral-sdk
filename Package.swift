// swift-tools-version: 6.0
import PackageDescription

// Phrover — the phone-brained WAVE ROVER. Three layered products:
//
//   RoverNav      pure Foundation planning/control core
//   PhroverKit    the brain: perception, nav orchestration, voice, ESP32 comms
//   PhroverCloud  mobile-side cloud client — MQTT telemetry, auth, dialog escalation
//
// PhroverCloud is split out so PhroverKit stays dependency-light: bring your own backend and
// only depend on RoverNav + PhroverKit, or take PhroverCloud for the reference AWS IoT/Cognito
// integration. Only the server side (fleet orchestration, video ingestion, pilot routing) is
// closed — see README.md.
//
// Platform floor: SwiftPM has no per-target platform override, so the package-wide iOS
// minimum is pinned to what PhroverKit's on-device Apple Foundation Model support actually
// requires (iOS 26), even though RoverNav's own code would run on much older iOS. macOS is
// declared only for RoverNav, which is pure Foundation and buildable/testable standalone
// there (`swift build --target RoverNav`) — PhroverKit/PhroverCloud import ARKit, which
// doesn't exist on macOS, so the package as a whole (and its full test suite, including
// RoverNavTests) needs an iOS destination:
//
//   xcodebuild test -scheme astral-sdk-Package -destination 'platform=iOS Simulator,name=...'
let package = Package(
    name: "astral-sdk",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "RoverNav", targets: ["RoverNav"]),
        .library(name: "PhroverKit", targets: ["PhroverKit"]),
        .library(name: "PhroverCloud", targets: ["PhroverCloud"]),
    ],
    dependencies: [
        .package(url: "https://github.com/aws-amplify/aws-sdk-ios-spm", from: "2.33.0"),
    ],
    targets: [
        .target(name: "RoverNav", path: "swift/Sources/RoverNav"),
        .testTarget(name: "RoverNavTests", dependencies: ["RoverNav"], path: "swift/Tests/RoverNavTests"),

        .target(
            name: "PhroverKit",
            dependencies: ["RoverNav"],
            path: "swift/Sources/PhroverKit",
            resources: [.copy("Resources/RoverYOLO.mlpackage")]
        ),
        .testTarget(name: "PhroverKitTests", dependencies: ["PhroverKit"], path: "swift/Tests/PhroverKitTests"),

        .target(
            name: "PhroverCloud",
            dependencies: [
                "PhroverKit",
                .product(name: "AWSCore", package: "aws-sdk-ios-spm"),
                .product(name: "AWSIoT", package: "aws-sdk-ios-spm"),
            ],
            path: "swift/Sources/PhroverCloud"
        ),
    ]
)
