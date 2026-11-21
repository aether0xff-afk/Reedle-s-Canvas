// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReedlesCanvas",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "ReedlesCanvas", targets: ["ReedlesCanvas"])
    ],
    targets: [
        .target(name: "ReedlesCanvas", path: "ReedlesCanvas")
    ],
    swiftLanguageModes: [.v5]
)
