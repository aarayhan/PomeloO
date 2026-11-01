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
        .target(name: "PomeloOCore"),
        // Menu bar app (LSUIElement) and its panels.
        .executableTarget(name: "PomeloOMac", dependencies: ["PomeloOCore"]),
        .testTarget(name: "PomeloOCoreTests", dependencies: ["PomeloOCore"]),
    ]
)
