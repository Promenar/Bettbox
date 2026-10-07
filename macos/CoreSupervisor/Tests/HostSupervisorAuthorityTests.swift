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
private func fixture(deadline: TimeInterval = 5) -> (Facts, HostSupervisorAuthority) {
    let facts = Facts()
    return (facts, HostSupervisorAuthority(facts: facts, authority: SSIAuthority(backend: facts), replyQueue: DispatchQueue(label: "test.reply"), deadline: deadline))
}
@main enum HostSupervisorAuthorityTests {
    static func main() {
        let (facts, bridge) = fixture()
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
        require(truth(invoke(slowBridge, "confirmStopped", slowStop)), "超时保留helper出生记录")
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
        require(code(invoke(preflightBridge, "reserveSupervisorLaunch", ["generation": 2])) == "sdk_busy", "预检晚返回前不能排新任务")
        for _ in 0..<16 { preflightGate.signal() }
        var higher: Result<Any?, HostSupervisorFailure>?
        for _ in 0..<100 {
            let attempt = invoke(preflightBridge, "reserveSupervisorLaunch", ["generation": 2])
            if code(attempt) != "sdk_busy" { higher = attempt; break }
        }
        require(higher != nil, "SDK退出后应释放未发行ticket")
        require(fields(higher!)["generation"] as? UInt64 == 2, "未发行ticket释放后仍使用更高代次")

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
        require(truth(invoke(coreDelayBridge, "confirmStopped", coreStop)), "两出生明确消失才能停止")
        for _ in 0..<16 { coreGate.signal() }
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
        let changedBridge = HostSupervisorAuthority(facts: changed, authority: changedAuthority, replyQueue: DispatchQueue(label: "test.changed.reply"))
        let changedLaunch = fields(invoke(changedBridge, "reserveSupervisorLaunch", ["generation": 1]))["launch"] as! String
        let changedHelper = fields(invoke(changedBridge, "bindSupervisor", ["launch": changedLaunch, "generation": 1, "pid": 12]))["handle"] as! String
        let changedCore = fields(invoke(changedBridge, "bindCoreChain", ["handle": changedHelper, "pid": 13]))["handle"] as! String
        require(code(invoke(changedBridge, "recheckCoreChain", ["handle": changedCore])) == "identity_failed", "SDK后提交点出生变化不能发行valid")
        guard case .present(let mutated) = changed.kernelRead(13) else { fatalError("出生变化必须实际发生") }
        require(mutated.birthSeconds == 31, "SDK之后出生变化必须发生，不能仅靠断言预期")
        print("HostSupervisorAuthority 测试完成")
    }
}
