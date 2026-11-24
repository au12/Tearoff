// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tearoff",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TearoffApp", targets: ["TearoffApp"]),
        .executable(name: "tearoff", targets: ["TearoffCLI"]),
        .executable(name: "tearoff-filter", targets: ["TearoffFilter"]),
    ],
    targets: [
        // Pure Swift: label finding, barcode analysis, grid-fitting, ZPL. No Apple frameworks.
        .target(name: "TearoffCore"),
        // macOS glue: Quartz PDF rendering, printing over TCP/CUPS, discovery, driver install.
        .target(name: "TearoffKit", dependencies: ["TearoffCore"]),
        .executableTarget(name: "TearoffApp", dependencies: ["TearoffKit"]),
        .executableTarget(name: "TearoffCLI", dependencies: ["TearoffKit"]),
        .executableTarget(name: "TearoffFilter", dependencies: ["TearoffKit"]),
        .testTarget(name: "TearoffCoreTests", dependencies: ["TearoffCore"]),
    ]
)
