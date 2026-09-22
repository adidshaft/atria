// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StrapProtocol",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StrapProtocol",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                // Embed Info.plist so macOS can show the Bluetooth usage string.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        )
    ]
)
