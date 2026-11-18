// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Voicepad",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VoicepadCore", targets: ["VoicepadCore"]),
        .executable(name: "Voicepad", targets: ["Voicepad"])
    ],
    targets: [
        .target(name: "VoicepadCore"),
        .executableTarget(name: "Voicepad", dependencies: ["VoicepadCore"]),
        .testTarget(name: "VoicepadCoreTests", dependencies: ["VoicepadCore"])
    ]
)
