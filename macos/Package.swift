// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WooTodoMac",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "WooTodoCore", targets: ["WooTodoCore"]),
        .library(name: "WooTodoStorage", targets: ["WooTodoStorage"]),
        .library(name: "WooTodoSync", targets: ["WooTodoSync"]),
        .executable(name: "woo-todo-mac", targets: ["WooTodoMacApp"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.4"
        )
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "WooTodoCore",
            path: "Sources/WooTodoCore"
        ),
        .target(
            name: "WooTodoStorage",
            dependencies: ["WooTodoCore", "WooTodoSync", "CSQLite"],
            path: "Sources/WooTodoStorage"
        ),
        .target(
            name: "WooTodoSync",
            path: "Sources/WooTodoSync",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "WooTodoMacApp",
            dependencies: [
                "WooTodoCore",
                "WooTodoStorage",
                "WooTodoSync",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/WooTodoMacApp"
        ),
        .testTarget(
            name: "WooTodoCoreTests",
            dependencies: ["WooTodoCore"],
            path: "Tests/WooTodoCoreTests"
        ),
        .testTarget(
            name: "WooTodoStorageTests",
            dependencies: ["WooTodoCore", "WooTodoStorage", "WooTodoSync"],
            path: "Tests/WooTodoStorageTests"
        ),
        .testTarget(
            name: "WooTodoSyncTests",
            dependencies: ["WooTodoSync"],
            path: "Tests/WooTodoSyncTests"
        ),
        .testTarget(
            name: "WooTodoMacAppTests",
            dependencies: ["WooTodoMacApp"],
            path: "Tests/WooTodoMacAppTests"
        )
    ]
)
