// swift-tools-version: 5.10

import PackageDescription

// The tree-sitter TSX grammar (TypeScript + JSX), vendored so kero can link it.
// See README.md for why this can't just come from STTextView-Plugin-Neon.
let package = Package(
    name: "TreeSitterTSX",
    products: [
        .library(name: "TreeSitterTSX", targets: ["TreeSitterTSX"])
    ],
    targets: [
        .target(name: "TreeSitterTSX", cSettings: [.headerSearchPath("src")])
    ]
)
