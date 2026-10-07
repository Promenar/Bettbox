import Flutter
import Foundation
import NetworkExtension
import BettboxCore

private final class ProviderReply {
  private let lock = NSLock()
  private var completed = false
  private let callback: (Result<Data, Error>) -> Void
  init(_ callback: @escaping (Result<Data, Error>) -> Void) { self.callback = callback }
  func finish(_ value: Result<Data, Error>) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    lock.unlock()
    DispatchQueue.main.async { self.callback(value) }
  }
}

final class BettboxIOSPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let controlQueue = DispatchQueue(label: "com.appshub.bettbox.runner.core", qos: .userInitiated)
  private var manager: NETunnelProviderManager?
  private var eventSink: FlutterEventSink?
  private var statusObserver: NSObjectProtocol?
  private var eventTimer: DispatchSourceTimer?
  private var offlineInFlight = false
  private var onlineInFlight = false
  private var publishInFlight = false
  private var managerGeneration = 0
  private let providerID = "com.appshub.bettbox.PacketTunnel"
  private var vpnSupported: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return true
    #endif
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BettboxIOSPlugin()
    let methods = FlutterMethodChannel(name: "bettbox/ios", binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: "bettbox/ios/events", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
    instance.statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak instance] notification in
      guard let instance, let connection = notification.object as? NEVPNConnection,
            connection === instance.manager?.connection else { return }
      instance.emitStatus()
    }
  }

  deinit {
    if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    eventTimer?.cancel()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "coreAction": coreAction(args, result: result)
    case "publishSnapshot":
      guard !publishInFlight else { result(failure("busy", "快照正在写入")); return }
      publishInFlight = true
      controlQueue.async {
        do {
          let snapshot = try SnapshotStore.publish(args)
          DispatchQueue.main.async { self.publishInFlight = false; result(snapshot) }
        } catch {
          DispatchQueue.main.async { self.publishInFlight = false; result(self.failure("snapshot", "配置快照发布失败")) }
        }
      }
    case "startVpn": startVpn(args, result: result)
    case "stopVpn":
      managerGeneration += 1
      if !vpnSupported { result(status()); return }
      loadManager { outcome in
        switch outcome {
        case .success(let manager):
          manager.connection.stopVPNTunnel()
          var value = self.status()
          value["accepted"] = true
          result(value)
        case .failure: result(self.failure("vpn", "系统 VPN 配置不可用"))
        }
      }
    case "getStatus":
      if !vpnSupported { result(status()); return }
      loadManager { outcome in
        switch outcome {
        case .success: result(self.status())
        case .failure: result(self.failure("vpn", "无法读取系统 VPN 状态"))
        }
      }
    case "sharedPaths":
      do {
        var value: [String: Any] = ["offlineCoreHome": try SnapshotStore.offlineHome().path, "appGroupID": SnapshotStore.appGroupID]
        if let shared = try? SnapshotStore.root() { value["snapshotRoot"] = shared.path; value["appGroupAvailable"] = true }
        else { value["appGroupAvailable"] = false }
        result(value)
      } catch { result(failure("storage", "本机核心目录不可用")) }
    case "getCapabilities":
      result(["schemaVersion": 1, "networkExtensionDeclared": true, "appGroupID": SnapshotStore.appGroupID,
              "appGroupAvailable": (try? SnapshotStore.root()) != nil,
              "requiresDeviceValidation": true, "offlineCore": true, "vpnSupported": vpnSupported])
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func loadManager(_ completion: @escaping (Result<NETunnelProviderManager, Error>) -> Void) {
    if let manager { completion(.success(manager)); return }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        if let error { completion(.failure(error)); return }
        let manager = self.manager ?? managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerID } ?? NETunnelProviderManager()
        self.manager = manager
        completion(.success(manager))
      }
    }
  }

  private func startVpn(_ args: [String: Any], result: @escaping FlutterResult) {
    guard vpnSupported else { result(failure("unsupported", "模拟器仅支持界面与离线核心调试，VPN 需要真机")); return }
    guard let revision = args["revision"] as? String, let hash = args["manifestHash"] as? String else {
      result(failure("argument", "启动需要 revision 与 manifestHash")); return
    }
    managerGeneration += 1
    let generation = managerGeneration
    controlQueue.async {
      do { _ = try SnapshotStore.load(revision: revision, expectedHash: hash) }
      catch { DispatchQueue.main.async { result(self.failure("snapshot", "启动快照校验失败")) }; return }
      DispatchQueue.main.async {
        guard generation == self.managerGeneration else { result(self.failure("cancelled", "启动已取消")); return }
        self.loadManager { outcome in
          switch outcome {
          case .failure: result(self.failure("vpn", "系统 VPN 配置不可用"))
          case .success(let manager):
            guard generation == self.managerGeneration else { result(self.failure("cancelled", "启动已取消")); return }
            guard manager.connection.status == .invalid || manager.connection.status == .disconnected else {
              result(self.failure("busy", "系统隧道尚未停止")); return
            }
            let protocolConfig = NETunnelProviderProtocol()
            protocolConfig.providerBundleIdentifier = self.providerID
            protocolConfig.serverAddress = "Bettbox"
            protocolConfig.providerConfiguration = ["schemaVersion": SnapshotStore.schemaVersion, "revision": revision, "manifestHash": hash]
            manager.protocolConfiguration = protocolConfig
            manager.localizedDescription = "Bettbox"
            manager.isEnabled = true
            manager.saveToPreferences { error in
              DispatchQueue.main.async {
                if error != nil { result(self.failure("permission", "保存 VPN 配置失败，请检查系统授权和签名能力")); return }
                guard generation == self.managerGeneration else { result(self.failure("cancelled", "启动已取消")); return }
                manager.loadFromPreferences { error in
                  DispatchQueue.main.async {
                    if error != nil { result(self.failure("vpn", "重载 VPN 配置失败")); return }
                    guard generation == self.managerGeneration else { result(self.failure("cancelled", "启动已取消")); return }
                    do {
                      try manager.connection.startVPNTunnel()
                      var value = self.status()
                      value["accepted"] = true
                      // accepted 仅代表请求交给系统，连接完成由 NE 状态事件确认。
                      result(value)
                      self.emitStatus()
                    } catch { result(self.failure("vpn", "系统拒绝启动隧道")) }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  private func coreAction(_ args: [String: Any], result: @escaping FlutterResult) {
    // 自动传输先读取系统已保存的会话，避免应用重开后错误选择离线核心。
    if manager == nil && vpnSupported {
      loadManager { outcome in
        switch outcome {
        case .success: self.coreAction(args, result: result)
        case .failure: result(self.failure("vpn", "无法确认系统隧道状态"))
        }
      }
      return
    }
    guard let action = args["action"] as? String, action.utf8.count <= 1024 * 1024,
          let data = action.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = object["method"] as? String else {
      result(failure("argument", "核心 Action 无效")); return
    }
    let transport = args["transport"] as? String ?? "auto"
    guard ["auto", "offline", "online"].contains(transport) else { result(failure("argument", "核心传输类型无效")); return }
    let timeout = min(30000, max(1, (args["timeoutMs"] as? NSNumber)?.int32Value ?? 10000))
    let status = manager?.connection.status ?? .invalid
    let online = status == .connected || status == .reasserting
    if transport == "online" || (transport == "auto" && online) {
      guard online else { result(failure("unavailable", "系统隧道尚未连接")); return }
      guard !onlineInFlight else { result(failure("busy", "扩展核心操作尚未完成")); return }
      onlineInFlight = true
      providerMessage(["schemaVersion": 1, "kind": "coreAction", "action": action, "timeoutMs": timeout], timeoutMs: Int(timeout) + 2000) { outcome in
        self.onlineInFlight = false
        switch outcome {
        case .success(let data):
          guard let response = String(data: data, encoding: .utf8) else { result(self.failure("protocol", "扩展回复不是 UTF-8")); return }
          result(response)
        case .failure: result(self.failure("timeout", "扩展控制请求失败或超时"))
        }
      }
      return
    }
    guard !online, status != .connecting, status != .disconnecting else { result(failure("busy", "隧道状态变化中，请等待系统状态")); return }
    guard !["startListener", "stopListener", "crash"].contains(method) else { result(failure("lifecycle", "隧道启停必须通过系统 VPN 方法")); return }
    guard !offlineInFlight else { result(failure("busy", "离线核心操作尚未完成")); return }
    offlineInFlight = true
    controlQueue.async {
      do {
        let response = try CoreClient.invoke(action, timeoutMs: timeout)
        DispatchQueue.main.async { self.offlineInFlight = false; result(response) }
      } catch {
        DispatchQueue.main.async { self.offlineInFlight = false; result(self.failure("core", "离线核心操作失败")) }
      }
    }
  }

  private func providerMessage(_ message: [String: Any], timeoutMs: Int, completion: @escaping (Result<Data, Error>) -> Void) {
    guard let session = manager?.connection as? NETunnelProviderSession,
          let data = try? JSONSerialization.data(withJSONObject: message), data.count <= 1024 * 1024 else {
      completion(.failure(BettboxNativeError(message: "扩展会话不可用"))); return
    }
    let reply = ProviderReply(completion)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
      reply.finish(.failure(BettboxNativeError(message: "扩展回复超时")))
    }
    do {
      try session.sendProviderMessage(data) { response in
        guard let response, response.count <= 4 * 1024 * 1024 else {
          reply.finish(.failure(BettboxNativeError(message: "扩展回复无效"))); return
        }
        reply.finish(.success(response))
      }
    } catch { reply.finish(.failure(error)) }
  }

  private func status() -> [String: Any] {
    let status = manager?.connection.status ?? .invalid
    let name: String
    switch status {
    case .invalid: name = "invalid"
    case .disconnected: name = "disconnected"
    case .connecting: name = "connecting"
    case .connected: name = "connected"
    case .reasserting: name = "reasserting"
    case .disconnecting: name = "disconnecting"
    @unknown default: name = "unknown"
    }
    var value: [String: Any] = ["status": name, "connected": status == .connected || status == .reasserting,
                               "transitioning": status == .connecting || status == .disconnecting,
                               "vpnSupported": vpnSupported]
    if let date = manager?.connection.connectedDate { value["connectedAt"] = Int64(date.timeIntervalSince1970 * 1000) }
    if let revision = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["revision"] as? String { value["revision"] = revision }
    return value
  }

  private func emitStatus() {
    var value = status()
    value["kind"] = "vpnStatus"
    eventSink?(value)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    loadManager { _ in self.emitStatus() }
    eventTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
    timer.setEventHandler { [weak self] in self?.pollEvents() }
    eventTimer = timer
    timer.resume()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    eventTimer?.cancel()
    eventTimer = nil
    return nil
  }

  private func pollEvents() {
    guard eventSink != nil, !onlineInFlight else { return }
    let status = manager?.connection.status ?? .invalid
    if status == .connected || status == .reasserting {
      onlineInFlight = true
      providerMessage(["schemaVersion": 1, "kind": "events"], timeoutMs: 2000) { result in
        self.onlineInFlight = false
        if case .success(let bytes) = result,
           let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let events = value["events"] as? [String] {
          for event in events { self.eventSink?(["kind": "coreMessage", "data": event]) }
        }
      }
    } else {
      for _ in 0..<16 {
        guard let event = try? CoreClient.take(bettbox_core_event_poll()), !event.isEmpty else { break }
        eventSink?(["kind": "coreMessage", "data": event])
      }
    }
  }

  private func failure(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
}
