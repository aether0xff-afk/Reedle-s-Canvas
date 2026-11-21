// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "ReedlesCanvas",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "ReedlesCanvas",
            targets: ["AppModule"],
            bundleIdentifier: "dev.aether.reedlescanvas",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad],
            supportedInterfaceOrientations: [
                .portrait, .landscapeLeft, .landscapeRight,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ]
        )
    ],
    targets: [.executableTarget(name: "AppModule", path: ".")]
)
