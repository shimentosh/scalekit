// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScaleKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScaleKit", targets: ["ScaleKit"]),
        .executable(name: "scalekit-diag", targets: ["scalekit-diag"]),
        .executable(name: "ScaleKitGuard", targets: ["ScaleKitGuard"]),
        .library(name: "ScaleKitCore", targets: ["ScaleKitCore"]),
        .library(name: "ScaleKitVirtual", targets: ["ScaleKitVirtual"]),
    ],
    targets: [
        // Hardware access, models and services. No UI code.
        .target(
            name: "ScaleKitCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ColorSync"),
            ]
        ),
        // EXPERIMENTAL. The only code that touches a private API (CGVirtualDisplay),
        // looked up at run time. Kept out of ScaleKitCore on purpose.
        .target(
            name: "ScaleKitVirtualBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        // Virtual-display HiDPI scaling (125–175% on low-density monitors) built on the bridge.
        .target(name: "ScaleKitVirtual", dependencies: ["ScaleKitCore", "ScaleKitVirtualBridge"]),
        // SwiftUI + AppKit application.
        .executableTarget(name: "ScaleKit", dependencies: ["ScaleKitCore", "ScaleKitVirtual"]),
        // Command-line diagnostic tool (milestone 1) and hardware validation harness.
        .executableTarget(name: "scalekit-diag", dependencies: ["ScaleKitCore", "ScaleKitVirtual"]),
        // Unprivileged watchdog that restores the display if ScaleKit hangs during a trial.
        .executableTarget(name: "ScaleKitGuard", dependencies: ["ScaleKitCore"]),
        .testTarget(name: "ScaleKitCoreTests", dependencies: ["ScaleKitCore"]),
    ]
)
