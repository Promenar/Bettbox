// swift-tools-version: 5.9
import PackageDescription

// 代理事务核心与隔离测试；真实系统配置适配器由原生插件提供。
let package = Package(name: "MacosProxyTransactionCore", platforms: [.macOS(.v12)],
    products: [.library(name: "MacosProxyTransactionCore", targets: ["MacosProxyTransactionCore"])],
    targets: [.target(name: "MacosProxyTransactionCore", path: "Classes/Core"),
              .testTarget(name: "MacosProxyTransactionCoreTests", dependencies: ["MacosProxyTransactionCore"], path: "Tests/Core")])
