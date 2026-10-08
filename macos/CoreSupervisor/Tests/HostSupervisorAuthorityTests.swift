import Foundation

private func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
private final class Descriptor: SSIHostHelperDescriptor {
    let path = "/fixture/BettboxCoreSupervisor"
    let context: SSIContext
    var heldFD: AnyObject { self }
    init(_ context: SSIContext) { self.context = context }
}
// fake SDK 只用于独立测试；proof 仍由实际 SSIAuthority 发行。
private final class Facts: SSIHostFacts, SSIBackend {
    let lock = NSLock()
    let host = SSIStamp(pid: 11, parent: 1, effectiveUID: 501, realUID: 501, birthSeconds: 10, birthMicros: 1)
    let helper = SSIStamp(pid: 12, parent: 11, effectiveUID: 501, realUID: 501, birthSeconds: 20, birthMicros: 1)
    let core = SSIStamp(pid: 13, parent: 12, effectiveUID: 501, realUID: 501, birthSeconds: 30, birthMicros: 1)
    var reads: [Int32: SSIHostKernelRead] = [:]
    var kernelHook: ((Int32) -> Void)?
    var sdkGate: DispatchSemaphore?
    var preflightGate: DispatchSemaphore?
    let entered = DispatchSemaphore(value: 0)
    var contextValue: SSIContext {
        let artifact = SSIArtifact(sha256: "fixture", identifier: "fixture", cliCDHash: "fixture", staticUnique: Data([1]))
        return SSIContext(host: host, seal: SSISeal(hostBundleUnique: Data([1]), helperStatic: artifact, coreStatic: artifact))
    }
    init() { reads[11] = .present(host); reads[12] = .present(helper); reads[13] = .present(core) }
    func set(_ pid: Int32, _ value: SSIHostKernelRead) { lock.lock(); reads[pid] = value; lock.unlock() }
    private func read(_ pid: Int32) -> SSIHostKernelRead { lock.lock(); defer { lock.unlock() }; return reads[pid] ?? .unknown }
    func kernelRead(_ pid: Int32) -> SSIHostKernelRead { kernelHook?(pid); return read(pid) }
    func context() throws -> SSIContext { contextValue }
    func stamp(_ pid: Int32) throws -> SSIStamp {
        guard case .present(let value) = read(pid) else { throw SSIError.invalidChild }; return value
    }
    func guestUnique(_ pid: Int32, kind: SSIGuest) throws -> Data {
        if let gate = sdkGate { entered.signal(); gate.wait() }
        return Data([1])
    }
    func verifiedHelperForHost() throws -> SSIHostHelperDescriptor {
        if let gate = preflightGate { entered.signal(); gate.wait() }
        return Descriptor(contextValue)
    }
}
// 在实际authority完成recheck后、返回宿主提交队列前注入出生变化。
private final class AfterRecheckAuthority: SSIHostProofAuthority {
    private let actual: SSIAuthority
    let after: () -> Void
    init(_ actual: SSIAuthority, after: @escaping () -> Void) { self.actual = actual; self.after = after }
    func reserveLaunch(generation: UInt64) throws -> UUID { try actual.reserveLaunch(generation: generation) }
    func bindSupervisor(locatorPID: Int32, launch: UUID, generation: UInt64) throws -> SSISupervisorProof {
        try actual.bindSupervisor(locatorPID: locatorPID, launch: launch, generation: generation)
    }
    func bindCoreChain(_ proof: SSISupervisorProof, coreLocatorPID: Int32) throws -> SSICoreProof {
        try actual.bindCoreChain(proof, coreLocatorPID: coreLocatorPID)
    }
    func recheck(_ proof: SSICoreProof) throws { try actual.recheck(proof); after() }
    func revoke(launch: UUID, generation: UInt64) { actual.revoke(launch: launch, generation: generation) }
}
private final class ProxyCoordinator: HostSystemProxyCoordinating {
    private let lock = NSLock()
    var prepareResult = SafeResult(status: .idle, generation: 0)
    var recoverResult = SafeResult(status: .idle, generation: 0)
    var startResult = SafeResult(status: .applied, generation: 1, changedGroups: 3)
    var restoreResult = SafeResult(status: .restored, generation: 2, changedGroups: 3)
    var holdPreparation = false
    var holdRecovery = false
    private var preparation: ((SafeResult) -> Void)?
    private var recovery: ((SafeResult) -> Void)?
    let recoveryEntered = DispatchSemaphore(value: 0)
    private(set) var starts: [EndpointEvidence] = []
    private(set) var restores = 0
    private(set) var recoveries = 0

    func prepare(completion: @escaping (SafeResult) -> Void) {
        lock.lock()
        if holdPreparation { preparation = completion; lock.unlock(); return }
        let result = prepareResult; lock.unlock(); completion(result)
    }
    func completePreparation() {
        lock.lock(); let completion = preparation; preparation = nil; let result = prepareResult; lock.unlock()
        completion?(result)
    }
    func recover(completion: @escaping (SafeResult) -> Void) {
        lock.lock(); recoveries += 1
        if holdRecovery { recovery = completion; lock.unlock(); recoveryEntered.signal(); return }
        let result = recoverResult; lock.unlock(); recoveryEntered.signal(); completion(result)
    }
    func completeRecovery() {
        lock.lock(); let completion = recovery; recovery = nil; let result = recoverResult; lock.unlock()
        completion?(result)
    }
    func start(_ capability: CredentialBlindEndpointCapability, completion: @escaping (SafeResult) -> Void) {
        lock.lock(); starts.append(capability.endpoint); let result = startResult; lock.unlock(); completion(result)
    }
    func restore(completion: @escaping (SafeResult) -> Void) {
        lock.lock(); restores += 1; let result = restoreResult; lock.unlock(); completion(result)
    }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts.count }
    var restoreCount: Int { lock.lock(); defer { lock.unlock() }; return restores }
}
private func invoke(_ bridge: HostSupervisorAuthority, _ method: String, _ fields: [String: Any]) -> Result<Any?, HostSupervisorFailure> {
    let done = DispatchSemaphore(value: 0)
    var value: Result<Any?, HostSupervisorFailure>?
    bridge.call(method, arguments: fields) { response in value = response; done.signal() }
    require(done.wait(timeout: .now() + 2) == .success, "桥没有及时回包")
    return value!
}
private func code(_ result: Result<Any?, HostSupervisorFailure>) -> String? {
    if case .failure(let error) = result { return error.code }; return nil
}
private func fields(_ result: Result<Any?, HostSupervisorFailure>) -> [String: Any] {
    guard case .success(let value) = result, let map = value as? [String: Any] else { fatalError("应返回字段") }; return map
}
private func truth(_ result: Result<Any?, HostSupervisorFailure>) -> Bool {
    guard case .success(let value) = result, let bool = value as? Bool else { fatalError("应返回布尔") }; return bool
}
private func fixture(deadline: TimeInterval = 5, proxy: ProxyCoordinator = ProxyCoordinator()) -> (Facts, HostSupervisorAuthority) {
    let facts = Facts()
    return (facts, HostSupervisorAuthority(facts: facts, authority: SSIAuthority(backend: facts), proxy: proxy,
                                           replyQueue: DispatchQueue(label: "test.reply"), deadline: deadline))
}
@main enum HostSupervisorAuthorityTests {
    static func main() {
        let (facts, bridge) = fixture()
        let coldRecovery = fields(invoke(bridge, "recoverSystemProxy", [:]))
        require(Set(coldRecovery.keys) == ["status", "transactionGeneration", "changedGroups", "unresolvedGroups"],
                "冷恢复只能返回固定安全字段")
        require(coldRecovery["status"] as? String == "idle", "空journal冷恢复必须明确返回idle")
        require((coldRecovery["transactionGeneration"] as? NSNumber)?.uint64Value == 0,
                "冷恢复事务代次必须来自原生生命周期")
        require((coldRecovery["changedGroups"] as? NSNumber)?.intValue == 0 &&
                (coldRecovery["unresolvedGroups"] as? NSNumber)?.intValue == 0,
                "空journal冷恢复不得报告系统代理变更")
        for invalid in [true, NSNumber(value: 1.0), 0, -1, "1"] as [Any] {
            require(code(invoke(bridge, "reserveSupervisorLaunch", ["generation": invalid])) == "invalid_arguments", "代次必须为严格整数")
        }
        require(code(invoke(bridge, "reserveSupervisorLaunch", ["generation": 1, "path": "/tmp"])) == "invalid_arguments", "禁止额外字段")
        let launch = fields(invoke(bridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let stop: [String: Any] = ["launch": launch, "generation": 1]
        require(code(invoke(bridge, "reserveSupervisorLaunch", ["generation": 2])) == "stop_unconfirmed", "旧代未停止不能替换")
        require(code(invoke(bridge, "bindSupervisor", ["launch": launch.uppercased(), "generation": 1, "pid": 12])) == "invalid_arguments", "UUID必须小写")
        let helper = fields(invoke(bridge, "bindSupervisor", stop.merging(["pid": 12]) { _, new in new }))["handle"] as! String
        let core = fields(invoke(bridge, "bindCoreChain", ["handle": helper, "pid": 13]))["handle"] as! String
        require(fields(invoke(bridge, "recheckCoreChain", ["handle": core]))["valid"] as? Bool == true, "真实proof应通过")
        _ = invoke(bridge, "revokeLaunch", stop)
        require(code(invoke(bridge, "recheckCoreChain", ["handle": core])) == "revoked", "撤销后不授权")
        facts.set(12, .absent); facts.set(13, .unknown)
        require(!truth(invoke(bridge, "confirmStopped", stop)), "未知Core不能视为消失")
        facts.set(13, .present(SSIStamp(pid: 13, parent: 99, effectiveUID: 0, realUID: 0, birthSeconds: 31, birthMicros: 1)))
        require(truth(invoke(bridge, "confirmStopped", stop)), "PID复用证明旧出生消失")
        _ = fields(invoke(bridge, "reserveSupervisorLaunch", ["generation": 2]))

        let (slow, slowBridge) = fixture(deadline: 0.03)
        let slowLaunch = fields(invoke(slowBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let slowStop: [String: Any] = ["launch": slowLaunch, "generation": 1]
        let gate = DispatchSemaphore(value: 0); slow.sdkGate = gate
        require(code(invoke(slowBridge, "bindSupervisor", slowStop.merging(["pid": 12]) { _, new in new })) == "timeout", "SDK必须超时")
        require(code(invoke(slowBridge, "reserveSupervisorLaunch", ["generation": 2])) == "sdk_busy", "迟到SDK仍占槽")
        // guestUnique 将多次进入；为已在执行的 job 提供足够许可，绝不创建新 job。
        for _ in 0..<16 { gate.signal() }
        slow.set(12, .absent)
        var slowStopped = false
        for _ in 0..<100 {
            if truth(invoke(slowBridge, "confirmStopped", slowStop)) { slowStopped = true; break }
        }
        require(slowStopped, "SDK worker退出后才可用保留的helper出生记录确认停止")
        require(code(invoke(slowBridge, "bindSupervisor", slowStop.merging(["pid": 12]) { _, new in new })) != nil, "迟到不能恢复权限")

        let (cancel, cancelBridge) = fixture()
        let canceledLaunch = fields(invoke(cancelBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let canceled: [String: Any] = ["launch": canceledLaunch, "generation": 1]
        _ = invoke(cancelBridge, "revokeLaunch", canceled)
        require(!truth(invoke(cancelBridge, "confirmStopped", canceled)), "缺出生记录不能确认停止")
        require(code(invoke(cancelBridge, "bindSupervisor", canceled.merging(["pid": 12]) { _, new in new })) == "revoked", "撤销旧launch仍cheap捕获出生")
        cancel.set(12, .absent)
        require(truth(invoke(cancelBridge, "confirmStopped", canceled)), "撤销记录可证明消失")
        let (preflight, preflightBridge) = fixture(deadline: 0.03)
        let preflightGate = DispatchSemaphore(value: 0); preflight.preflightGate = preflightGate
        require(code(invoke(preflightBridge, "reserveSupervisorLaunch", ["generation": 1])) == "timeout", "预检未回launch也必须内部撤销")
        require(!truth(invoke(preflightBridge, "confirmPreflightStopped", ["generation": 1])), "SDK仍活跃不能确认停止")
        require(code(invoke(preflightBridge, "reserveSupervisorLaunch", ["generation": 2])) == "sdk_busy", "预检晚返回前不能排新任务")
        for _ in 0..<16 { preflightGate.signal() }
        var preflightStopped = false
        for _ in 0..<100 {
            if truth(invoke(preflightBridge, "confirmPreflightStopped", ["generation": 1])) {
                preflightStopped = true; break
            }
        }
        require(preflightStopped, "SDK退出后的内部撤销可确认未发行预检停止")
        require(!truth(invoke(preflightBridge, "confirmPreflightStopped", ["generation": 2])), "错代不能消费停止证据")
        require(code(invoke(preflightBridge, "confirmPreflightStopped", ["generation": 1, "launch": "伪造"])) == "invalid_arguments", "预检停止拒绝额外字段")
        let higher = invoke(preflightBridge, "reserveSupervisorLaunch", ["generation": 2])
        require(fields(higher)["generation"] as? UInt64 == 2, "确认后可预检更高代次")
        require(!truth(invoke(preflightBridge, "confirmPreflightStopped", ["generation": 2])), "已发行reservation不得用预检停止清理")

        let (missingCore, missingCoreBridge) = fixture()
        let missingLaunch = fields(invoke(missingCoreBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let missingStop: [String: Any] = ["launch": missingLaunch, "generation": 1]
        _ = fields(invoke(missingCoreBridge, "bindSupervisor", missingStop.merging(["pid": 12]) { _, new in new }))
        _ = invoke(missingCoreBridge, "revokeLaunch", missingStop)
        missingCore.set(12, .absent)
        require(!truth(invoke(missingCoreBridge, "confirmStopped", missingStop)), "已发行helperproof且缺Core出生时保持未知")

        let (coreDelay, coreDelayBridge) = fixture(deadline: 0.03)
        let coreLaunch = fields(invoke(coreDelayBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let coreStop: [String: Any] = ["launch": coreLaunch, "generation": 1]
        let bound = fields(invoke(coreDelayBridge, "bindSupervisor", coreStop.merging(["pid": 12]) { _, new in new }))["handle"] as! String
        let coreGate = DispatchSemaphore(value: 0); coreDelay.sdkGate = coreGate
        require(code(invoke(coreDelayBridge, "bindCoreChain", ["handle": bound, "pid": 13])) == "timeout", "Core SDK超时撤销")
        coreDelay.set(12, .absent); coreDelay.set(13, .unknown)
        require(!truth(invoke(coreDelayBridge, "confirmStopped", coreStop)), "Core SDK开始前的出生记录不能丢失")
        coreDelay.set(13, .absent)
        require(!truth(invoke(coreDelayBridge, "confirmStopped", coreStop)), "SDK worker仍占槽时不能提前确认停止")
        for _ in 0..<16 { coreGate.signal() }
        var coreStopped = false
        for _ in 0..<100 {
            if truth(invoke(coreDelayBridge, "confirmStopped", coreStop)) { coreStopped = true; break }
        }
        require(coreStopped, "SDK worker退出且两出生明确消失才能停止")
        if !CommandLine.arguments.contains("--recheck-only") {
        let (cross, crossBridge) = fixture(deadline: 0.03)
        let crossLaunch = fields(invoke(crossBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        var helperReads = 0
        cross.kernelHook = { pid in
            if pid == 12 { helperReads += 1; if helperReads == 2 { Thread.sleep(forTimeInterval: 0.06) } }
        }
        require(code(invoke(crossBridge, "bindSupervisor", ["launch": crossLaunch, "generation": 1, "pid": 12])) == "timeout", "提交kernel读取跨期限不能发行handle")

        }
        let changed = Facts()
        let changedAuthority = AfterRecheckAuthority(SSIAuthority(backend: changed)) {
            changed.set(13, .present(SSIStamp(pid: 13, parent: 12, effectiveUID: 501, realUID: 501, birthSeconds: 31, birthMicros: 1)))
            FileHandle.standardOutput.write(Data("SDK_AFTER_RECHECK_MUTATED\n".utf8))
        }
        let changedBridge = HostSupervisorAuthority(facts: changed, authority: changedAuthority,
            proxy: ProxyCoordinator(), replyQueue: DispatchQueue(label: "test.changed.reply"))
        let changedLaunch = fields(invoke(changedBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let changedHelper = fields(invoke(changedBridge, "bindSupervisor", ["launch": changedLaunch, "generation": 1, "pid": 12]))["handle"] as! String
        let changedCore = fields(invoke(changedBridge, "bindCoreChain", ["handle": changedHelper, "pid": 13]))["handle"] as! String
        require(code(invoke(changedBridge, "recheckCoreChain", ["handle": changedCore])) == "identity_failed", "SDK后提交点出生变化不能发行valid")
        guard case .present(let mutated) = changed.kernelRead(13) else { fatalError("出生变化必须实际发生") }
        require(mutated.birthSeconds == 31, "SDK之后出生变化必须发生，不能仅靠断言预期")

        let coldProxy = ProxyCoordinator(); coldProxy.holdPreparation = true
        let (_, coldBridge) = fixture(proxy: coldProxy)
        let coldDone = DispatchSemaphore(value: 0)
        var coldReservation: Result<Any?, HostSupervisorFailure>?
        coldBridge.call("reserveSupervisorLaunch", arguments: ["generation": 1]) {
            coldReservation = $0; coldDone.signal()
        }
        require(coldDone.wait(timeout: .now() + 0.03) == .timedOut, "cold recover完成前不得调用reserve")
        require(code(invoke(coldBridge, "reserveSupervisorLaunch", ["generation": 2])) == "system_proxy_recovering",
                "cold recover期间只允许挂起一个reserve")
        coldProxy.completePreparation()
        require(coldDone.wait(timeout: .now() + 1) == .success &&
                fields(coldReservation!)["generation"] as? UInt64 == 1, "cold recover安全后才发行reservation")

        let blockedProxy = ProxyCoordinator()
        blockedProxy.prepareResult = SafeResult(status: .permissionDenied, generation: 0)
        let (_, blockedBridge) = fixture(proxy: blockedProxy)
        require(code(invoke(blockedBridge, "reserveSupervisorLaunch", ["generation": 1])) ==
                "system_proxy_recovery_required", "cold recover非安全状态必须阻断reserve")
        require(fields(invoke(blockedBridge, "recoverSystemProxy", [:]))["status"] as? String == "idle",
                "显式无proof恢复可以解除cold阻断")

        let heldRecoveryProxy = ProxyCoordinator(); heldRecoveryProxy.holdRecovery = true
        let (_, heldRecoveryBridge) = fixture(proxy: heldRecoveryProxy)
        let heldRecoveryDone = DispatchSemaphore(value: 0)
        var heldRecoveryResult: Result<Any?, HostSupervisorFailure>?
        heldRecoveryBridge.call("recoverSystemProxy", arguments: [:]) {
            heldRecoveryResult = $0; heldRecoveryDone.signal()
        }
        require(heldRecoveryProxy.recoveryEntered.wait(timeout: .now() + 1) == .success,
                "显式recover必须先进入native coordinator")
        let rejectedReserveDone = DispatchSemaphore(value: 0)
        var rejectedReserve: Result<Any?, HostSupervisorFailure>?
        heldRecoveryBridge.call("reserveSupervisorLaunch", arguments: ["generation": 1]) {
            rejectedReserve = $0; rejectedReserveDone.signal()
        }
        require(rejectedReserveDone.wait(timeout: .now() + 0.1) == .success &&
                code(rejectedReserve!) == "system_proxy_recovering",
                "显式recover期间reserve必须立即拒绝，不能挂入cold pending槽")
        heldRecoveryProxy.completeRecovery()
        require(heldRecoveryDone.wait(timeout: .now() + 1) == .success &&
                fields(heldRecoveryResult!)["status"] as? String == "idle", "显式recover完成必须回安全wire")
        require(fields(invoke(heldRecoveryBridge, "reserveSupervisorLaunch", ["generation": 1]))["generation"] as? UInt64 == 1,
                "显式recover安全完成后才可发行新reservation")

        let heldFailureProxy = ProxyCoordinator(); heldFailureProxy.holdRecovery = true
        heldFailureProxy.recoverResult = SafeResult(status: .conflict, generation: 1, unresolvedGroups: 1)
        let (_, heldFailureBridge) = fixture(proxy: heldFailureProxy)
        let heldFailureDone = DispatchSemaphore(value: 0)
        heldFailureBridge.call("recoverSystemProxy", arguments: [:]) { _ in heldFailureDone.signal() }
        require(heldFailureProxy.recoveryEntered.wait(timeout: .now() + 1) == .success,
                "失败恢复必须先进入native coordinator")
        heldFailureProxy.completeRecovery()
        require(heldFailureDone.wait(timeout: .now() + 1) == .success, "显式recover失败也必须完成原请求")
        require(code(invoke(heldFailureBridge, "reserveSupervisorLaunch", ["generation": 1])) ==
                "system_proxy_recovery_required", "显式recover失败后必须保持reserve阻断")

        let proxy = ProxyCoordinator()
        let (proxyFacts, proxyBridge) = fixture(proxy: proxy)
        let proxyLaunch = fields(invoke(proxyBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let proxyStop: [String: Any] = ["launch": proxyLaunch, "generation": 1]
        let proxyHelper = fields(invoke(proxyBridge, "bindSupervisor", proxyStop.merging(["pid": 12]) { _, new in new }))["handle"] as! String
        let proxyCore = fields(invoke(proxyBridge, "bindCoreChain", ["handle": proxyHelper, "pid": 13]))["handle"] as! String
        let activation: [String: Any] = ["handle": proxyCore, "generation": 1, "listenerEpoch": 1,
            "host": "127.0.0.1", "port": 7890, "state": "active", "bypass": ["localhost"]]
        require(code(invoke(proxyBridge, "activateOwnedSystemProxy", activation.merging(["extra": true]) { _, new in new })) ==
                "invalid_arguments", "代理激活拒绝额外字段")
        for invalid in [true, NSNumber(value: 1.0), 0, -1] as [Any] {
            require(code(invoke(proxyBridge, "activateOwnedSystemProxy",
                                activation.merging(["listenerEpoch": invalid]) { _, new in new })) == "invalid_arguments",
                    "listenerEpoch必须为严格正整数")
        }
        let applied = fields(invoke(proxyBridge, "activateOwnedSystemProxy", activation))
        require(Set(applied.keys) == ["status", "transactionGeneration", "changedGroups", "unresolvedGroups"] &&
                applied["status"] as? String == "applied", "激活只返回固定安全wire")
        require(proxy.startCount == 1 && proxy.starts.first?.host == "127.0.0.1", "原生proof后二次核验才提交SC start")
        require(fields(invoke(proxyBridge, "activateOwnedSystemProxy", activation))["status"] as? String == "applied" &&
                proxy.startCount == 1, "相同epoch与端点只能幂等返回")
        require(code(invoke(proxyBridge, "activateOwnedSystemProxy",
                            activation.merging(["port": 7891]) { _, new in new })) == "stale",
                "相同epoch不得更换端点")
        require(code(invoke(proxyBridge, "activateOwnedSystemProxy",
                            activation.merging(["listenerEpoch": 2]) { _, new in new })) == "stop_unconfirmed",
                "更高epoch必须等待旧SC责任恢复")
        require(code(invoke(proxyBridge, "restoreSystemProxy", ["generation": 1, "listenerEpoch": 2])) == "stale",
                "restore必须匹配原生保存的epoch")
        let restored = fields(invoke(proxyBridge, "restoreSystemProxy", ["generation": 1, "listenerEpoch": 1]))
        require(restored["status"] as? String == "restored" && proxy.restoreCount == 1,
                "restore不依赖活proof并清理原生责任")

        let failedProxy = ProxyCoordinator()
        failedProxy.startResult = SafeResult(status: .recoveryRequired, generation: 1)
        failedProxy.restoreResult = SafeResult(status: .restored, generation: 2, unresolvedGroups: 1)
        let (failedFacts, failedBridge) = fixture(proxy: failedProxy)
        let failedLaunch = fields(invoke(failedBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let failedStop: [String: Any] = ["launch": failedLaunch, "generation": 1]
        let failedHelper = fields(invoke(failedBridge, "bindSupervisor", failedStop.merging(["pid": 12]) { _, new in new }))["handle"] as! String
        let failedCore = fields(invoke(failedBridge, "bindCoreChain", ["handle": failedHelper, "pid": 13]))["handle"] as! String
        let failedActivation = activation.merging(["handle": failedCore]) { _, new in new }
        require(fields(invoke(failedBridge, "activateOwnedSystemProxy", failedActivation))["status"] as? String ==
                "recoveryRequired", "SC失败必须作为安全状态返回")
        require(code(invoke(failedBridge, "revokeLaunch", failedStop)) == "system_proxy_recovery_required",
                "存在未解决组时revoke不得清除SC责任")
        failedFacts.set(12, .absent); failedFacts.set(13, .absent)
        require(!truth(invoke(failedBridge, "confirmStopped", failedStop)), "SC责任未清时不能确认停止")
        require(code(invoke(failedBridge, "reserveSupervisorLaunch", ["generation": 2])) ==
                "system_proxy_recovery_required", "SC责任未清时不能发行新代次")

        let raceProxy = ProxyCoordinator()
        let (raceFacts, raceBridge) = fixture(proxy: raceProxy)
        let raceLaunch = fields(invoke(raceBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let raceStop: [String: Any] = ["launch": raceLaunch, "generation": 1]
        let raceHelper = fields(invoke(raceBridge, "bindSupervisor", raceStop.merging(["pid": 12]) { _, new in new }))["handle"] as! String
        let raceCore = fields(invoke(raceBridge, "bindCoreChain", ["handle": raceHelper, "pid": 13]))["handle"] as! String
        let raceGate = DispatchSemaphore(value: 0); raceFacts.sdkGate = raceGate
        let raceDone = DispatchSemaphore(value: 0)
        var raceActivation: Result<Any?, HostSupervisorFailure>?
        raceBridge.call("activateOwnedSystemProxy", arguments: activation.merging(["handle": raceCore]) { _, new in new }) {
            raceActivation = $0; raceDone.signal()
        }
        require(raceFacts.entered.wait(timeout: .now() + 1) == .success, "激活必须进入真实proof recheck")
        require(fields(invoke(raceBridge, "recoverSystemProxy", [:]))["status"] as? String == "idle",
                "无proof恢复必须能同步废止pending激活")
        for _ in 0..<16 { raceGate.signal() }
        require(raceDone.wait(timeout: .now() + 1) == .success && code(raceActivation!) != nil,
                "恢复后的迟到SDK不能重新发布激活")
        require(raceProxy.startCount == 0, "恢复后迟到SDK不得调用SC start")
        _ = proxyFacts
        print("HostSupervisorAuthority 测试完成")
    }
}
