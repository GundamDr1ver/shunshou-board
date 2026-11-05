// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SimpleBoard", platforms: [.macOS(.v14)], products: [.executable(name: "SimpleBoard", targets: ["Board"])], targets: [.executableTarget(name: "Board", path: "Sources/Board"), .target(name:"BoardQuickLook",path:"Sources/BoardQuickLook"), .testTarget(name: "BoardTests", dependencies: ["Board","BoardQuickLook"], path: "Tests")])
