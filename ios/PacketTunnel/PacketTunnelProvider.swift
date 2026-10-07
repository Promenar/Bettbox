import Foundation
import NetworkExtension
import BettboxCore
import Darwin

private final class StartupReply {
  private let lock = NSLock()
  private var completed = false
  private let callback: (Error?) -> Void
  init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
  @discardableResult func finish(_ error: Error?) -> Bool {
    lock.lock()
    guard !completed else { lock.unlock(); return false }
    completed = true
    lock.unlock()
    callback(error)
    return true
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let controlQueue = DispatchQueue(label: "com.appshub.bettbox.tunnel.control", qos: .userInitiated)
  private let packetQueue = DispatchQueue(label: "com.appshub.bettbox.tunnel.packets", qos: .userInitiated)
  private let lifecycleLock = NSLock()
  private var lifecycleGeneration = 0
  private var messageInFlight = false
  private var packetGeneration = 0
  private var active = false
  private var timer: DispatchSourceTimer?
  private var mtu = 1480
  private var runtimeHome: URL?

  private func newGeneration() -> Int {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    lifecycleGeneration += 1
    return lifecycleGeneration
  }

  private func current(_ generation: Int) -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return lifecycleGeneration == generation
  }

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    let generation = newGeneration()
    let reply = StartupReply(completionHandler)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) { [weak self] in
      guard let self, self.current(generation), reply.finish(BettboxNativeError(message: "隧道启动超时")) else { return }
      _ = self.newGeneration()
      self.stopPackets()
      self.controlQueue.async { self.cleanupCore() }
    }
    controlQueue.async { [weak self] in
      guard let self else { reply.finish(BettboxNativeError(message: "隧道扩展已释放")); return }
      do {
        guard self.current(generation),
              let configuration = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              (configuration["schemaVersion"] as? NSNumber)?.intValue == SnapshotStore.schemaVersion,
              let revision = configuration["revision"] as? String,
              let hash = configuration["manifestHash"] as? String else {
          throw BettboxNativeError(message: "隧道配置或版本无效")
        }
        let snapshot = try SnapshotStore.load(revision: revision, expectedHash: hash)
        if try CoreClient.checkedAction("getIsInit")["data"] as? Bool == true {
          _ = try CoreClient.checkedAction("shutdown")
        }
        self.removeRuntimeHome()
        // provider 缓存可能被核心更新，运行目录不能污染用于重启校验的不可变快照。
        let home = try SnapshotStore.prepareRuntimeHome(revision, snapshot: snapshot)
        self.runtimeHome = home
        let initJSON = try CoreClient.json(["home-dir": home.path, "version": 15])
        let initialized = try CoreClient.checkedAction("initClash", data: initJSON)
        guard initialized["data"] as? Bool == true else { throw BettboxNativeError(message: "核心初始化失败") }
        _ = try CoreClient.checkedAction("setupConfig", data: snapshot.setup)
        if !snapshot.state.isEmpty { _ = try CoreClient.checkedAction("setState", data: snapshot.state) }
        guard self.current(generation) else { throw BettboxNativeError(message: "启动请求已取消") }
        let settings = try snapshot.network.settings()
        self.setTunnelNetworkSettings(settings) { [weak self] error in
          guard let self else { reply.finish(BettboxNativeError(message: "隧道扩展已释放")); return }
          self.controlQueue.async {
            do {
              if let error { throw error }
              guard self.current(generation) else { throw BettboxNativeError(message: "启动请求已取消") }
              try CoreClient.start(snapshot.network)
              guard self.current(generation) else { throw BettboxNativeError(message: "启动请求已取消") }
              if reply.finish(nil) { self.startPackets(mtu: snapshot.network.mtu, lifecycle: generation) }
            } catch {
              reply.finish(error)
              self.stopPackets()
              self.cleanupCore()
            }
          }
        }
      } catch {
        reply.finish(error)
        self.stopPackets()
        self.cleanupCore()
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    _ = newGeneration()
    stopPackets()
    let reply = StartupReply { _ in completionHandler() }
    // 截止时间独立于控制队列；超时仅归还系统回调，清理仍排队执行。
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
      reply.finish(BettboxNativeError(message: "隧道停止等待超时"))
    }
    controlQueue.async {
      // 系统负责停止扩展；核心超时不被误当作已经完成，但必须归还系统停止回调。
      do {
        try CoreClient.stop()
        _ = try CoreClient.checkedAction("shutdown")
        self.removeRuntimeHome()
      } catch {
        self.cancelTunnelWithError(BettboxNativeError(message: "核心停止未完成"))
      }
      reply.finish(nil)
    }
  }

  private func removeRuntimeHome() {
    if let home = runtimeHome { try? FileManager.default.removeItem(at: home) }
    runtimeHome = nil
  }

  private func cleanupCore() {
    do {
      try CoreClient.stop()
      _ = try CoreClient.checkedAction("shutdown")
      removeRuntimeHome()
    } catch {
      // 超时工作可能仍占用目录，因此不删除正在使用的运行副本。
    }
  }

  private func startPackets(mtu: Int, lifecycle: Int) {
    packetQueue.async { [self] in
      guard self.current(lifecycle), bettbox_core_status() == 1 else { return }
      self.packetGeneration += 1
      let generation = self.packetGeneration
      self.mtu = mtu
      self.active = true
      self.readPackets(generation)
      let timer = DispatchSource.makeTimerSource(queue: self.packetQueue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
      timer.setEventHandler { [weak self] in self?.pollPackets(generation) }
      self.timer = timer
      timer.resume()
    }
  }

  private func stopPackets() {
    packetQueue.async {
      self.active = false
      self.packetGeneration += 1
      self.timer?.cancel()
      self.timer = nil
    }
  }

  private func readPackets(_ generation: Int) {
    guard active, packetGeneration == generation else { return }
    packetFlow.readPackets { [weak self] packets, protocols in
      guard let self else { return }
      self.packetQueue.async {
        guard self.active, self.packetGeneration == generation else { return }
        for (index, packet) in packets.enumerated() {
          guard index < protocols.count, packet.count <= self.mtu, !packet.isEmpty else { continue }
          let version = packet[packet.startIndex] >> 4
          let family = protocols[index].int32Value
          guard (version == 4 && family == AF_INET) || (version == 6 && family == AF_INET6) else { continue }
          packet.withUnsafeBytes { bytes in
            _ = bettbox_core_packet_push(UnsafeMutableRawPointer(mutating: bytes.baseAddress), Int32(packet.count))
          }
        }
        self.readPackets(generation)
      }
    }
  }

  private func pollPackets(_ generation: Int) {
    guard active, packetGeneration == generation else { return }
    var storage = [UInt8](repeating: 0, count: mtu)
    var packets: [Data] = []
    var protocols: [NSNumber] = []
    // 每轮限制包数，避免持续回包抢占输入与停止队列。
    for _ in 0..<64 {
      var version: Int32 = 0
      let count = storage.withUnsafeMutableBytes { bytes in
        bettbox_core_packet_poll(bytes.baseAddress, Int32(mtu), &version)
      }
      if count == 0 { break }
      guard count > 0, count <= Int32(mtu), version == 4 || version == 6 else {
        active = false
        timer?.cancel()
        timer = nil
        cancelTunnelWithError(BettboxNativeError(message: "核心包流已中断"))
        return
      }
      packets.append(Data(storage.prefix(Int(count))))
      protocols.append(NSNumber(value: version == 4 ? AF_INET : AF_INET6))
    }
    if !packets.isEmpty, !packetFlow.writePackets(packets, withProtocols: protocols) {
      active = false
      timer?.cancel()
      timer = nil
      cancelTunnelWithError(BettboxNativeError(message: "系统拒绝回包"))
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    guard let completionHandler else { return }
    guard messageData.count <= 1024 * 1024 else { completionHandler(errorReply("控制消息超过上限")); return }
    lifecycleLock.lock()
    guard !messageInFlight else {
      lifecycleLock.unlock()
      completionHandler(errorReply("扩展控制队列忙"))
      return
    }
    messageInFlight = true
    lifecycleLock.unlock()
    controlQueue.async {
      defer {
        self.lifecycleLock.lock()
        self.messageInFlight = false
        self.lifecycleLock.unlock()
      }
      do {
        guard let request = try JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              (request["schemaVersion"] as? NSNumber)?.intValue == 1 else {
          throw BettboxNativeError(message: "控制协议版本无效")
        }
        if request["kind"] as? String == "events" {
          var events: [String] = []
          var size = 0
          for _ in 0..<16 {
            let event = try CoreClient.take(bettbox_core_event_poll())
            if event.isEmpty { break }
            size += event.utf8.count
            guard size <= 256 * 1024 else { break }
            events.append(event)
          }
          completionHandler(try JSONSerialization.data(withJSONObject: ["events": events]))
          return
        }
        guard request["kind"] as? String == "coreAction", let action = request["action"] as? String,
              let data = action.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String,
              !["initClash", "setupConfig", "startListener", "stopListener", "shutdown", "crash"].contains(method),
              bettbox_core_status() == 1 else {
          throw BettboxNativeError(message: "该操作需要由系统隧道生命周期管理")
        }
        let timeout = min(30000, max(1, (request["timeoutMs"] as? NSNumber)?.int32Value ?? 10000))
        let response = try CoreClient.invoke(action, timeoutMs: timeout)
        completionHandler(response.data(using: .utf8))
      } catch { completionHandler(self.errorReply("扩展控制操作失败")) }
    }
  }

  private func errorReply(_ message: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["id": "", "method": "", "code": -1, "data": message])) ?? Data()
  }
}
