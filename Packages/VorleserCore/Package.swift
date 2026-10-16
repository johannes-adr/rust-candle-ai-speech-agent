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
    dependencies: [],
    targets: [
        .target(name: "TextPrep"),
        // VORLÄUFIG (Merge: wieder auf dependencies: ["TextPrep"] zurückdrehen,
        // siehe Sources/DocumentImport/TextDocumentShim.swift).
        .target(name: "DocumentImport"),
        .target(name: "Speech", dependencies: ["TextPrep"]),
        .target(name: "AudioOut"),
        .target(name: "Projects", dependencies: ["TextPrep"]),
        .executableTarget(
            name: "vorleser-cli",
            dependencies: ["DocumentImport", "TextPrep", "Speech", "AudioOut", "Projects"]
        ),
        // Spike S4: liest einen Ordner mit PDFs und schreibt die erkannten Blöcke als .txt.
        .executableTarget(name: "spike-s4", dependencies: ["DocumentImport"]),
        .testTarget(name: "TextPrepTests", dependencies: ["TextPrep"]),
        .testTarget(
            name: "DocumentImportTests",
            dependencies: ["DocumentImport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SpeechTests", dependencies: ["Speech"]),
        .testTarget(name: "AudioOutTests", dependencies: ["AudioOut"]),
        .testTarget(name: "ProjectsTests", dependencies: ["Projects"]),
    ]
)
