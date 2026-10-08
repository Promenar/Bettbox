// swift-tools-version: 5.9
import PackageDescription

// HTTP代理事务核心、SystemConfiguration后端与只读SDK验收；App接线独立验收。
let package = Package(name: "MacosProxyTransactionCore", platforms: [.macOS(.v12)],
    products: [.library(name: "MacosProxyTransactionCore", targets: ["MacosProxyTransactionCore"])],
    targets: [.target(name: "MacosProxyTransactionCore", path: "Classes/Core"),
              .testTarget(name: "MacosProxyTransactionCoreTests", dependencies: ["MacosProxyTransactionCore"], path: "Tests/Core")])
