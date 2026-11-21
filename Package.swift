// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GamePort",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GamePortKit", targets: ["GamePortKit"]),
        .executable(name: "gameport", targets: ["gameport"]),
        .executable(name: "GamePortApp", targets: ["GamePortApp"]),
    ],
    targets: [
        // Recipes and engine manifests live in Data/ and are embedded by Scripts/embed-data.py,
        // so the app needs no resource bundle.
        .target(name: "GamePortKit"),
        .executableTarget(name: "gameport", dependencies: ["GamePortKit"]),
        .executableTarget(name: "GamePortApp", dependencies: ["GamePortKit"]),
        .executableTarget(name: "import-recipes", dependencies: ["GamePortKit"], path: "Tools/import-recipes"),
        .testTarget(name: "GamePortKitTests", dependencies: ["GamePortKit"]),
    ]
)
