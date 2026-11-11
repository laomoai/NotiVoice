// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NotiVoice", platforms: [.macOS(.v13)], products: [.executable(name: "NotiVoice", targets: ["NotiVoice"])], targets: [
    .executableTarget(name: "NotiVoice", path: "NotiVoice"),
    .testTarget(name: "NotiVoiceTests", dependencies: ["NotiVoice"], path: "Tests/NotiVoiceTests")
])
