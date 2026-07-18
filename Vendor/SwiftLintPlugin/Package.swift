// swift-tools-version: 5.9
// No-op stand-in for lukepistrol/SwiftLintPlugin. CodeEditSourceEditor runs
// this lint plugin on its own targets; the bundled SwiftLint binary crashes
// under the Xcode beta toolchain ("Loading sourcekitdInProc failed"), and
// linting a dependency's sources is not our concern anyway. Having a local
// package with the same identity overrides the remote one.

import PackageDescription

let package = Package(
    name: "SwiftLintPlugin",
    products: [
        .plugin(name: "SwiftLint", targets: ["SwiftLint"])
    ],
    targets: [
        .plugin(name: "SwiftLint", capability: .buildTool())
    ]
)
