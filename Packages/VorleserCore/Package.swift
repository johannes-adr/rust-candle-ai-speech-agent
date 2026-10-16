// swift-tools-version: 6.2
import PackageDescription

// Kern der Vorleser-App ohne UI. Jedes Modul ist einzeln testbar.
let package = Package(
    name: "VorleserCore",
    defaultLocalization: "de",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DocumentImport", targets: ["DocumentImport"]),
        .library(name: "TextPrep", targets: ["TextPrep"]),
        .library(name: "Speech", targets: ["Speech"]),
        .library(name: "AudioOut", targets: ["AudioOut"]),
        .library(name: "Projects", targets: ["Projects"]),
        .executable(name: "vorleser-cli", targets: ["vorleser-cli"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "TextPrep"),
        .target(name: "DocumentImport", dependencies: ["TextPrep"]),
        .target(name: "Speech", dependencies: ["TextPrep"]),
        // LAME 3.100 (LGPL) als eigenes C-Target, nur Encoder. Siehe docs/spikes/S5-mp3.md.
        .target(
            name: "CLAME",
            exclude: ["COPYING", "LICENSE", "README.lame"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
            ]
        ),
        .target(name: "AudioOut", dependencies: ["CLAME"]),
        .target(name: "Projects", dependencies: ["TextPrep"]),
        .executableTarget(
            name: "vorleser-cli",
            dependencies: ["DocumentImport", "TextPrep", "Speech", "AudioOut", "Projects"]
        ),
        // Spike S4: liest einen Ordner mit PDFs und schreibt die erkannten Blöcke als .txt.
        .executableTarget(name: "spike-s4", dependencies: ["DocumentImport", "TextPrep"]),
        .testTarget(name: "TextPrepTests", dependencies: ["TextPrep"]),
        .testTarget(
            name: "DocumentImportTests",
            dependencies: ["DocumentImport", "TextPrep"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SpeechTests", dependencies: ["Speech"]),
        .testTarget(name: "AudioOutTests", dependencies: ["AudioOut"]),
        .testTarget(name: "ProjectsTests", dependencies: ["Projects"]),
    ]
)
