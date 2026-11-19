// swift-tools-version: 6.0
import PackageDescription

// Shaped like ztron-routing-kit: a pure core that builds and tests with `swift test` on any platform,
// and the Apple-only layers (StoreKit, SwiftUI, CloudKit) added only where Darwin exists.

var products: [Product] = [
    .library(name: "ZTronPaywallCore", targets: ["PaywallCore"]),
    // Debug builds and test targets only: every source file is wrapped in `#if DEBUG`, so a release build of an app that
    // links it (directly, or through ZTronPaywallSimulator) ships none of the fakes, and a non-debug reference to one
    // is a compile error. `Scripts/check-release-symbols.sh` checks that it defines no Swift symbol in release.
    .library(name: "ZTronPaywallTesting", targets: ["PaywallTesting"]),
]

var targets: [Target] = [
    .target(
        name: "PaywallCore",
        dependencies: [
            .product(name: "Logging", package: "swift-log")
        ],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "PaywallTesting",
        dependencies: [
            .target(name: "PaywallCore")
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "PaywallCoreTests",
        dependencies: [
            .target(name: "PaywallCore"),
            .target(name: "PaywallTesting"),
        ],
        swiftSettings: swiftSettings
    ),
]

#if canImport(Darwin)
    products += [
        .library(name: "ZTronPaywallKit", targets: ["PaywallKit"]),
        .library(name: "ZTronPaywallCloudSync", targets: ["PaywallCloudSync"]),
        // Link from Debug configurations only: every source file is wrapped in `#if DEBUG`, in this module and in the
        // PaywallTesting module it depends on, so the two compile to nothing in release (checked by
        // `Scripts/check-release-symbols.sh`).
        .library(name: "ZTronPaywallSimulator", targets: ["PaywallSimulator"]),
    ]
    targets += [
        .target(
            name: "PaywallKit",
            dependencies: [
                .target(name: "PaywallCore"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PaywallCloudSync",
            dependencies: [
                .target(name: "PaywallCore")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PaywallSimulator",
            dependencies: [
                .target(name: "PaywallKit"),
                .target(name: "PaywallTesting"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PaywallKitTests",
            dependencies: [
                .target(name: "PaywallKit"),
                .target(name: "PaywallTesting"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PaywallCloudSyncTests",
            dependencies: [
                .target(name: "PaywallCloudSync"),
                .target(name: "PaywallTesting"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PaywallSimulatorTests",
            dependencies: [
                .target(name: "PaywallSimulator"),
                .target(name: "PaywallKit"),
                .target(name: "PaywallTesting"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
#endif

let package = Package(
    name: "ZTronPaywallKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4")
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]
}
