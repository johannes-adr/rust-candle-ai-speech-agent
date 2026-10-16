// swift-tools-version: 6.0
import PackageDescription

// Kern der Vorleser-App ohne UI. Jedes Modul ist einzeln testbar.
let package = Package(
    name: "VorleserCore",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DocumentImport", targets: ["DocumentImport"]),
        .library(name: "TextPrep", targets: ["TextPrep"]),
        .library(name: "Speech", targets: ["Speech"]),
        .library(name: "AudioOut", targets: ["AudioOut"]),
        .library(name: "Projects", targets: ["Projects"]),
        .executable(name: "vorleser-cli", targets: ["vorleser-cli"]),
    ],
    dependencies: [
        // Exakt gepinnt (Tag v0.1.5), siehe docs/spikes/S1-engine.md
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "dbe5eaac964e8257785f9d015c81f819a38016a8"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.6"),
    ],
    targets: [
        .target(name: "TextPrep"),
        .target(name: "DocumentImport", dependencies: ["TextPrep"]),
        .target(
            name: "Speech",
            dependencies: [
                "TextPrep",
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(name: "spike-s1", dependencies: ["Speech", "TextPrep"]),
        .target(name: "AudioOut"),
        .target(name: "Projects", dependencies: ["TextPrep"]),
        .executableTarget(
            name: "vorleser-cli",
            dependencies: ["DocumentImport", "TextPrep", "Speech", "AudioOut", "Projects"]
        ),
        .testTarget(name: "TextPrepTests", dependencies: ["TextPrep"]),
        .testTarget(name: "DocumentImportTests", dependencies: ["DocumentImport"]),
        .testTarget(name: "SpeechTests", dependencies: ["Speech"]),
        .testTarget(name: "AudioOutTests", dependencies: ["AudioOut"]),
        .testTarget(name: "ProjectsTests", dependencies: ["Projects"]),
    ]
)
