import Foundation
import BettboxCore

struct BettboxNativeError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

// 调用方在独立控制队列上使用同步 C ABI；Go 自身限制同时一个控制任务。
enum CoreClient {
  static func invoke(_ action: String, timeoutMs: Int32 = 10000) throws -> String {
    let bytes = action.utf8CString
    guard bytes.count - 1 <= 1024 * 1024 else {
      throw BettboxNativeError(message: "核心请求超过大小上限")
    }
    return try bytes.withUnsafeBufferPointer { buffer in
      try take(bettbox_core_action(UnsafeMutablePointer(mutating: buffer.baseAddress), Int32(bytes.count - 1), timeoutMs))
    }
  }

  static func checkedAction(_ method: String, data: String? = nil) throws -> [String: Any] {
    var request: [String: Any] = ["id": UUID().uuidString, "method": method]
    if let data { request["data"] = data }
    let response = try invoke(json(request))
    return try checkedReply(response)
  }

  static func start(_ network: SnapshotNetwork) throws {
    let payload: [String: Any] = [
      "mtu": network.mtu, "capacity": network.capacity,
      "ipv4-address": network.ipv4Address, "ipv6-address": network.ipv6Address,
      "dns-hijack": ["any:53"],
    ]
    let bytes = try json(payload).utf8CString
    let response = try bytes.withUnsafeBufferPointer { buffer in
      try take(bettbox_core_start(UnsafeMutablePointer(mutating: buffer.baseAddress), Int32(bytes.count - 1), 30000))
    }
    let reply = try checkedReply(response)
    guard reply["data"] as? Bool == true, bettbox_core_status() == 1 else {
      throw BettboxNativeError(message: "核心未完成启动")
    }
  }

  static func stop() throws {
    let response = try take(bettbox_core_stop(30000))
    _ = try checkedReply(response)
    guard bettbox_core_lifecycle() == 0 else {
      throw BettboxNativeError(message: "核心停止尚未完成")
    }
  }

  static func checkedReply(_ response: String) throws -> [String: Any] {
    guard let bytes = response.data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          let code = value["code"] as? NSNumber else {
      throw BettboxNativeError(message: "核心回复格式无效")
    }
    guard code.intValue == 0 else {
      // 参数和配置正文不进入系统日志。
      throw BettboxNativeError(message: "核心操作失败")
    }
    return value
  }

  static func take(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String {
    guard let pointer else { throw BettboxNativeError(message: "核心未返回回复") }
    defer { bettbox_core_free(pointer) }
    return String(cString: pointer)
  }

  static func json(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
      throw BettboxNativeError(message: "JSON 编码失败")
    }
    return text
  }
}
