// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomeloO",
    platforms: [.macOS(.v13)],
    products: [
        // Contents/MacOS/PomeloO; make-app.sh takes this executable.
        .executable(name: "PomeloO", targets: ["PomeloOMac"]),
        .library(name: "PomeloOCore", targets: ["PomeloOCore"]),
    ],
    targets: [
        // Catalog, naming, engines, job runner. No UI, so `swift test` covers it.
        .target(
            name: "PomeloOCore",
            resources: [
                // Resources/catalog.json is a symlink to docs/catalog.json (the shared source of truth).
                // Embedded in the binary: SwiftPM resource bundles do not survive inside a hand-made .app.
                .embedInCode("Resources/catalog.json"),
            ]
        ),
        // Menu bar app (LSUIElement) and its panels.
        .executableTarget(name: "PomeloOMac", dependencies: ["PomeloOCore"]),
        .testTarget(name: "PomeloOCoreTests", dependencies: ["PomeloOCore"]),
        // Drawing checks for the AppKit views: rendered offscreen, no screen or permission needed.
        .testTarget(name: "PomeloOMacTests", dependencies: ["PomeloOMac", "PomeloOCore"]),
    ]
)
