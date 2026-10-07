import Foundation
import Darwin

// 只测生产authority状态和解码器；不模拟真实签名成功或guest真实性。
private final class SSIFake: SSIBackend {
    let host = SSIStamp(pid: 100, parent: 90, effectiveUID: 501, realUID: 501, birthSeconds: 1, birthMicros: 0)
    var processes: [Int32: SSIStamp] = [:]
    var seal = SSISeal(hostBundleUnique: Data([1]),
        helperStatic: SSIArtifact(sha256: "helper", identifier: "helper", cliCDHash: "h", staticUnique: Data([2])),
        coreStatic: SSIArtifact(sha256: "core", identifier: "core", cliCDHash: "c", staticUnique: Data([3])))
    var onGuest: ((SSIGuest) throws -> Void)?
    var onContext: (() throws -> Void)?
    var wrongUnique = false
    init() {
        processes[100] = host
        processes[200] = SSIStamp(pid: 200, parent: 100, effectiveUID: 501, realUID: 501, birthSeconds: 2, birthMicros: 0)
        processes[300] = SSIStamp(pid: 300, parent: 200, effectiveUID: 501, realUID: 501, birthSeconds: 3, birthMicros: 0)
    }
    func context() throws -> SSIContext {
        try onContext?()
        return SSIContext(host: host, seal: seal)
    }
    func stamp(_ locator: Int32) throws -> SSIStamp {
        guard let value = processes[locator] else { throw SSIError.invalidChild }; return value
    }
    func guestUnique(_ locator: Int32, kind: SSIGuest) throws -> Data {
        try onGuest?(kind)
        if wrongUnique { return Data([9]) }
        switch kind { case .host: return seal.hostBundleUnique; case .supervisor: return seal.helperStatic.staticUnique; case .core: return seal.coreStatic.staticUnique }
    }
    func change(_ pid: Int32, parent: Int32? = nil, uid: UInt32? = nil, birth: UInt64? = nil, actualPID: Int32? = nil) {
        let old = processes[pid]!
        processes[pid] = SSIStamp(pid: actualPID ?? old.pid, parent: parent ?? old.parent,
            effectiveUID: uid ?? old.effectiveUID, realUID: old.realUID, birthSeconds: birth ?? old.birthSeconds, birthMicros: old.birthMicros)
    }
}
private func SSIReject(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw NSError(domain: "SSI fixture accepted invalid evidence", code: 1)
}
// 主控以独立临时main调用；候选不包含可跳过真实签名的生产main。
func runSSIFixtures() throws -> [String] {
    var passed: [String] = []
    for name in ["validDistinctUnique", "wrongparent", "UID", "PIDbirth", "helperChangedBetweenCoreCheck", "staticManifestChange", "locatorMismatch", "wrongUnique", "cancelSDKLate"] {
        let fake = SSIFake()
        // 每个case实际使用同一个fake注入生产authority。
        let owner = SSIAuthority(backend: fake)
        let launch = try owner.reserveLaunch(generation: 1)
        if name == "wrongparent" { fake.change(200, parent: 90) }
        if name == "UID" { fake.change(200, uid: 502) }
        if name == "locatorMismatch" { fake.change(200, actualPID: 201) }
        if name == "wrongUnique" { fake.wrongUnique = true }
        if ["wrongparent", "UID", "locatorMismatch", "wrongUnique"].contains(name) {
            try SSIReject { _ = try owner.bindSupervisor(locatorPID: 200, launch: launch, generation: 1) }
        } else {
            let helper = try owner.bindSupervisor(locatorPID: 200, launch: launch, generation: 1)
            if name == "PIDbirth" {
                let proof = try owner.bindCoreChain(helper, coreLocatorPID: 300)
                fake.change(300, birth: 9); try SSIReject { try owner.recheck(proof) }
            } else if name == "helperChangedBetweenCoreCheck" {
                fake.onGuest = { if $0 == .core { fake.change(200, birth: 9) } }
                try SSIReject { _ = try owner.bindCoreChain(helper, coreLocatorPID: 300) }
            } else if name == "staticManifestChange" {
                fake.seal = SSISeal(hostBundleUnique: fake.seal.hostBundleUnique, helperStatic: fake.seal.helperStatic,
                    coreStatic: SSIArtifact(sha256: "changed", identifier: "core", cliCDHash: "c", staticUnique: Data([3])))
                try SSIReject { _ = try owner.bindCoreChain(helper, coreLocatorPID: 300) }
            } else if name == "cancelSDKLate" {
                var newLaunch: UUID?
                fake.onGuest = { kind in
                    if kind == .core {
                        fake.onGuest = nil
                        owner.revoke(launch: launch, generation: 1)
                        newLaunch = try owner.reserveLaunch(generation: 2)
                    }
                }
                try SSIReject { _ = try owner.bindCoreChain(helper, coreLocatorPID: 300) }
                // 旧worker catch不能撤销新代。
                let fresh = try owner.bindSupervisor(locatorPID: 200, launch: newLaunch!, generation: 2)
                let proof = try owner.bindCoreChain(fresh, coreLocatorPID: 300); try owner.recheck(proof)
            } else {
                let proof = try owner.bindCoreChain(helper, coreLocatorPID: 300); try owner.recheck(proof)
                owner.revoke(launch: launch, generation: 1); try SSIReject { try owner.recheck(proof) }
            }
        }
        passed.append(name)
    }
    // Core已核验后，后续helper或seal的SDK期间改变Core，提交前必须拒绝。
    for operation in ["bind", "recheck"] {
        for window in ["helper", "context"] {
            for mutation in ["birth", "parent", "UID"] {
                let fake = SSIFake()
                let authority = SSIAuthority(backend: fake)
                let launch = try authority.reserveLaunch(generation: 1)
                let helper = try authority.bindSupervisor(locatorPID: 200, launch: launch, generation: 1)
                let existing: SSICoreProof? = operation == "recheck" ? try authority.bindCoreChain(helper, coreLocatorPID: 300) : nil
                var sawCore = false
                var mutated = false
                func changeCore() {
                    guard sawCore, !mutated else { return }
                    mutated = true
                    switch mutation {
                    case "birth": fake.change(300, birth: 9)
                    case "parent": fake.change(300, parent: 999)
                    default: fake.change(300, uid: 502)
                    }
                }
                fake.onGuest = { kind in
                    if kind == .core { sawCore = true }
                    if kind == .supervisor && window == "helper" { changeCore() }
                }
                fake.onContext = { if window == "context" { changeCore() } }
                try SSIReject {
                    if let proof = existing { try authority.recheck(proof) }
                    else { _ = try authority.bindCoreChain(helper, coreLocatorPID: 300) }
                }
                guard mutated else { throw NSError(domain: "SSI fixture missing mutation", code: 2) }
                passed.append(operation + "LateCore" + window + mutation)
            }
        }
    }
    var bsd = proc_bsdinfo(); bsd.pbi_pid = 200; bsd.pbi_ppid = 100; bsd.pbi_start_tvsec = 1
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    try SSIReject { _ = try SSIKernelDecoder.decode(bsd, count: size - 1, locator: 200) }; passed.append("shortRead")
    bsd.pbi_status = UInt32(SZOMB)
    try SSIReject { _ = try SSIKernelDecoder.decode(bsd, count: size, locator: 200) }; passed.append("zombie")
    return passed
}
