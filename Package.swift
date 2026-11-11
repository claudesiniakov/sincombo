// swift-tools-version:5.10
import PackageDescription

// Минимальная версия системы — macOS 14; она же продублирована в Info.plist (scripts/build-app.sh).
let package = Package(
    name: "SinCombo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SinCombo", targets: ["SinCombo"]),
        .library(name: "SinComboCore", targets: ["SinComboCore"]),
    ],
    targets: [
        .target(name: "SinComboCore"),
        .executableTarget(name: "SinCombo", dependencies: ["SinComboCore"]),
        .testTarget(name: "SinComboCoreTests", dependencies: ["SinComboCore"]),
    ]
)
