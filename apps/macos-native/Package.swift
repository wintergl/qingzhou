// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SplitVPNNative", platforms: [.macOS(.v14)],
    products: [.executable(name: "SplitVPNNative", targets: ["SplitVPNNative"])],
    targets: [.executableTarget(name: "SplitVPNNative"), .testTarget(name: "SplitVPNNativeTests", dependencies: ["SplitVPNNative"])])
