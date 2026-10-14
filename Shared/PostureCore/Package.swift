// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PostureCore", products: [.executable(name: "PostureCore", targets: ["PostureCore"])],
    targets: [.executableTarget(name: "PostureCore"), .testTarget(name: "PostureCoreTests", dependencies: ["PostureCore"])])
