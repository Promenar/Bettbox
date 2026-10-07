import Foundation
import CryptoKit

struct SnapshotResource: Codable {
  let path: String
  let size: Int
  let sha256: String
}

struct CoreSnapshot: Codable {
  let schemaVersion: Int
  let revision: String
  let setup: String
  let state: String
  let network: SnapshotNetwork
  let resources: [SnapshotResource]
}

// 共享文件只包含核心运行必需的配置及资源；登录 token 不使用共享偏好或清单字段。
enum SnapshotStore {
  static let schemaVersion = 1

  static var appGroupID: String {
    Bundle.main.object(forInfoDictionaryKey: "BettboxAppGroupIdentifier") as? String ?? ""
  }

  static func root() throws -> URL {
    guard !appGroupID.isEmpty, !appGroupID.contains("$("),
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
      throw BettboxNativeError(message: "App Group 尚未可用，请完成签名能力配置")
    }
    let directory = container.appendingPathComponent("BettboxSnapshots", isDirectory: true)
    try createProtected(directory)
    return directory
  }

  static func offlineHome() throws -> URL {
    let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = base.appendingPathComponent("BettboxOfflineCore", isDirectory: true)
    try createProtected(directory)
    return directory
  }

  static func coreHome(_ revision: String) throws -> URL {
    try validRevision(revision)
    return try root().appendingPathComponent(revision, isDirectory: true).appendingPathComponent("core", isDirectory: true)
  }

  static func prepareRuntimeHome(_ revision: String, snapshot: CoreSnapshot) throws -> URL {
    let source = try coreHome(revision)
    let home = source.deletingLastPathComponent().appendingPathComponent("runtime-" + UUID().uuidString.lowercased(), isDirectory: true)
    try validateResources(source, resources: snapshot.resources)
    do {
      try FileManager.default.copyItem(at: source, to: home)
      try protect(home)
      try validateResources(home, resources: snapshot.resources)
      return home
    } catch {
      try? FileManager.default.removeItem(at: home)
      throw error
    }
  }

  static func publish(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let setup = arguments["setup"] as? String, setup.utf8.count <= 1024 * 1024,
          let setupBytes = setup.data(using: .utf8),
          let setupObject = try JSONSerialization.jsonObject(with: setupBytes) as? [String: Any],
          let config = setupObject["config"] as? [String: Any],
          Set(setupObject.keys).isSubset(of: ["config", "selected-map", "test-url", "override-test-url"]),
          let networkObject = arguments["network"] as? [String: Any] else {
      throw BettboxNativeError(message: "共享配置快照格式无效")
    }
    let network = try SnapshotNetwork(networkObject)
    guard (config["ipv6"] as? Bool ?? false) == !network.ipv6Address.isEmpty else {
      throw BettboxNativeError(message: "配置与网络设置的 IPv6 状态不一致")
    }
    let state = arguments["state"] as? String ?? ""
    if !state.isEmpty {
      guard state.utf8.count <= 64 * 1024, let bytes = state.data(using: .utf8),
            let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(value.keys).isSubset(of: ["vpn-props", "only-statistics-proxy", "current-profile-name", "bypass-domain"]) else {
        throw BettboxNativeError(message: "核心状态快照格式无效")
      }
    }
    let revision = UUID().uuidString.lowercased()
    let base = try root()
    let staging = base.appendingPathComponent(".staging-" + revision, isDirectory: true)
    try createProtected(staging)
    do {
      let home = staging.appendingPathComponent("core", isDirectory: true)
      try createProtected(home)
      var resources: [SnapshotResource] = []
      var copiedSources: [String: String] = [:]
      var paths: Set<String> = []
      var total = 0
      let rawResources = arguments["resources"] as? [[String: Any]] ?? []
      guard rawResources.count <= 512 else { throw BettboxNativeError(message: "核心资源数量超过上限") }
      for resource in rawResources {
        guard let path = resource["path"] as? String, let sourcePath = resource["sourcePath"] as? String else {
          throw BettboxNativeError(message: "资源输入格式无效")
        }
        try validPath(path)
        guard paths.insert(path).inserted else { throw BettboxNativeError(message: "资源路径重复") }
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.resolvingSymlinksInPath()
        let privateRoot = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard source.path.hasPrefix(privateRoot) else { throw BettboxNativeError(message: "资源必须来自容器应用的私有目录") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let size = values.fileSize ?? -1
        guard values.isRegularFile == true, size >= 0, size <= 64 * 1024 * 1024 else {
          throw BettboxNativeError(message: "资源类型或大小无效")
        }
        let destination = home.appendingPathComponent(path)
        try createProtected(destination.deletingLastPathComponent())
        let copiedSize = try boundedCopy(source, to: destination, limit: min(64 * 1024 * 1024, 256 * 1024 * 1024 - total))
        total += copiedSize
        try protect(destination)
        copiedSources[source.path] = path
        resources.append(SnapshotResource(path: path, size: copiedSize, sha256: try hashFile(destination)))
      }
      try validateResources(home, resources: resources)
      var rewrittenSetup = setupObject
      var rewrittenConfig = config
      // provider 缓存路径限定在当前快照核心目录，绝对源路径必须对应显式资源输入。
      for key in ["proxy-providers", "rule-providers"] {
        if var providers = rewrittenConfig[key] as? [String: [String: Any]] {
          for (name, var provider) in providers {
            if let path = provider["path"] as? String {
              let relative: String
              if path.hasPrefix("/") {
                let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                guard let mapped = copiedSources[source] else { throw BettboxNativeError(message: "provider 绝对路径没有匹配的共享资源") }
                relative = mapped
              } else { relative = path }
              try validPath(relative)
              provider["path"] = relative
              providers[name] = provider
            }
          }
          rewrittenConfig[key] = providers
        }
      }
      rewrittenSetup["config"] = rewrittenConfig
      let snapshot = CoreSnapshot(schemaVersion: schemaVersion, revision: revision, setup: try CoreClient.json(rewrittenSetup), state: state, network: network, resources: resources)
      let data = try JSONEncoder().encode(snapshot)
      let manifest = staging.appendingPathComponent("snapshot.json")
      try data.write(to: manifest, options: [.atomic])
      try protect(manifest)
      try FileManager.default.moveItem(at: staging, to: base.appendingPathComponent(revision, isDirectory: true))
      return ["schemaVersion": schemaVersion, "revision": revision, "manifestHash": hash(data)]
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  static func load(revision: String, expectedHash: String) throws -> CoreSnapshot {
    try validRevision(revision)
    guard expectedHash.count == 64, expectedHash.allSatisfy({ $0.isHexDigit }) else {
      throw BettboxNativeError(message: "快照摘要无效")
    }
    let directory = try root().appendingPathComponent(revision, isDirectory: true)
    let manifest = directory.appendingPathComponent("snapshot.json")
    let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 2 * 1024 * 1024 else { throw BettboxNativeError(message: "快照清单大小无效") }
    let data = try Data(contentsOf: manifest)
    guard hash(data) == expectedHash else { throw BettboxNativeError(message: "快照摘要不一致") }
    let snapshot = try JSONDecoder().decode(CoreSnapshot.self, from: data)
    guard snapshot.schemaVersion == schemaVersion, snapshot.revision == revision, snapshot.resources.count <= 512 else {
      throw BettboxNativeError(message: "不支持该快照版本")
    }
    try snapshot.network.validate()
    let home = directory.appendingPathComponent("core", isDirectory: true)
    try validateResources(home, resources: snapshot.resources)
    return snapshot
  }

  static func validateResources(_ home: URL, resources: [SnapshotResource]) throws {
    let rootValues = try home.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true, resources.count <= 512 else {
      throw BettboxNativeError(message: "核心资源目录无效")
    }
    var expected: Set<String> = []
    var total = 0
    for resource in resources {
      try validPath(resource.path)
      guard expected.insert(resource.path).inserted, resource.size >= 0, resource.size <= 64 * 1024 * 1024 else {
        throw BettboxNativeError(message: "核心资源清单无效")
      }
      total += resource.size
      guard total <= 256 * 1024 * 1024 else { throw BettboxNativeError(message: "核心资源总量超过上限") }
      let file = home.appendingPathComponent(resource.path)
      let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
      guard resolved.path.hasPrefix(home.standardizedFileURL.path + "/"),
            try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]).isRegularFile == true,
            try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == resource.size,
            try hashFile(file) == resource.sha256 else {
        throw BettboxNativeError(message: "核心资源校验失败")
      }
    }
    var actual: Set<String> = []
    var enumerationFailed = false
    guard let entries = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
      throw BettboxNativeError(message: "无法检查核心资源目录")
    }
    for case let entry as URL in entries {
      let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
        throw BettboxNativeError(message: "核心资源包含不允许的路径类型")
      }
      if values.isRegularFile == true { actual.insert(String(entry.path.dropFirst(home.path.count + 1))) }
    }
    guard !enumerationFailed, actual == expected else { throw BettboxNativeError(message: "核心资源文件集合与清单不一致") }
  }

  static func boundedCopy(_ source: URL, to destination: URL, limit: Int) throws -> Int {
    guard limit >= 0, !FileManager.default.fileExists(atPath: destination.path),
          FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw BettboxNativeError(message: "无法创建共享资源文件")
    }
    try protect(destination)
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var total = 0
    while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      guard chunk.count <= limit - total else { throw BettboxNativeError(message: "复制资源超过大小上限") }
      try output.write(contentsOf: chunk)
      total += chunk.count
    }
    try output.synchronize()
    return total
  }

  static func validRevision(_ text: String) throws {
    guard let uuid = UUID(uuidString: text), uuid.uuidString.lowercased() == text else {
      throw BettboxNativeError(message: "快照 revision 无效")
    }
  }

  static func validPath(_ path: String) throws {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
          !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), !path.contains("\0") else {
      throw BettboxNativeError(message: "共享资源路径无效")
    }
  }

  static func createProtected(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
  }

  static func protect(_ url: URL) throws {
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
  }

  static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  static func hashFile(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
