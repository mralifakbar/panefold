// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Panefold",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Panefold", targets: ["Panefold"]),
    ],
    targets: [
        .target(
            name: "PanefoldCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Panefold",
            dependencies: ["PanefoldCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(
            name: "PanefoldCoreTests",
            dependencies: ["PanefoldCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
