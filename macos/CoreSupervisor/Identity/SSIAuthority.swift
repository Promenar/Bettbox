import Foundation

enum SSIError: Error { case invalidArtifact, invalidManifest, invalidSignature, invalidChild, stale, revoked }
enum SSIRole: Equatable { case host, supervisor }
struct SSIStamp: Equatable {
    let pid: Int32, parent: Int32
    let effectiveUID: UInt32, realUID: UInt32
    let birthSeconds: UInt64, birthMicros: UInt64
}
struct SSIArtifact: Equatable {
    let sha256: String, identifier: String, cliCDHash: String
    let staticUnique: Data
}
// Bundle与helper是不同签名对象，绝不要求两个Unique相等。
struct SSISeal: Equatable {
    let hostBundleUnique: Data
    let helperStatic: SSIArtifact, coreStatic: SSIArtifact
}
struct SSIContext {
    let host: SSIStamp
    let seal: SSISeal
}
protocol SSIBackend {
    func context() throws -> SSIContext
    func stamp(_ locator: Int32) throws -> SSIStamp
    func guestUnique(_ locator: Int32, kind: SSIGuest) throws -> Data
}
enum SSIGuest: Equatable { case host, supervisor, core }
struct SSISupervisorProof { fileprivate let token: UUID }
struct SSICoreProof { fileprivate let token: UUID }

// 身份worker只读取事实。Security调用期间不持意图锁，不启动/等待/回收/发信号/写pipe。
final class SSIAuthority {
    private struct Intent: Equatable { let launch: UUID; let generation: UInt64; let epoch: UInt64 }
    private struct Helper { let intent: Intent; let context: SSIContext; let stamp: SSIStamp }
    private struct Chain { let helperToken: UUID; let helper: Helper; let core: SSIStamp }
    private let lock = NSLock()
    private let backend: SSIBackend
    private var active: Intent?
    private var generation: UInt64 = 0
    private var epoch: UInt64 = 0
    private var helpers: [UUID: Helper] = [:]
    private var chains: [UUID: Chain] = [:]
    init(backend: SSIBackend) { self.backend = backend }

    // 必须在排队前预留。launch由native生成，调用者不能覆盖内核事实。
    func reserveLaunch(generation next: UInt64) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard next > generation, epoch < UInt64.max else { throw SSIError.stale }
        generation = next; epoch += 1
        let launch = UUID(); active = Intent(launch: launch, generation: next, epoch: epoch)
        helpers.removeAll(); chains.removeAll(); return launch
    }
    private func capture(_ launch: UUID, _ generation: UInt64) throws -> Intent {
        lock.lock(); defer { lock.unlock() }
        guard let value = active, value.launch == launch, value.generation == generation else { throw SSIError.stale }
        return value
    }
    private func commit(_ intent: Intent, body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard active == intent else { throw SSIError.stale }; try body()
    }
    private func check(_ value: SSIStamp, locator: Int32, parent: SSIStamp) throws {
        guard locator > 0, value.pid == locator, value.parent == parent.pid,
              value.effectiveUID == parent.effectiveUID, value.realUID == parent.realUID,
              value.birthSeconds > 0, value.birthMicros < 1_000_000 else { throw SSIError.invalidChild }
    }
    private func verifyHost(_ context: SSIContext) throws {
        guard try backend.stamp(context.host.pid) == context.host,
              try backend.guestUnique(context.host.pid, kind: .host) == context.seal.hostBundleUnique,
              try backend.stamp(context.host.pid) == context.host else { throw SSIError.invalidChild }
    }
    private func verifyHelper(_ helper: Helper) throws {
        try verifyHost(helper.context)
        let before = try backend.stamp(helper.stamp.pid)
        try check(before, locator: helper.stamp.pid, parent: helper.context.host)
        guard before == helper.stamp,
              try backend.guestUnique(before.pid, kind: .supervisor) == helper.context.seal.helperStatic.staticUnique,
              try backend.stamp(before.pid) == before else { throw SSIError.invalidChild }
    }
    // 所有SDK完成后读取整链最终内核事实；此后到提交之间不再调用SDK。
    // 检查与后续业务不是内核原子事务，proof仅保留已核验出生链。
    private func finalStamps(_ helper: Helper, core: SSIStamp? = nil) throws {
        let hostNow = try backend.stamp(helper.context.host.pid)
        let helperNow = try backend.stamp(helper.stamp.pid)
        guard hostNow == helper.context.host, helperNow == helper.stamp else { throw SSIError.invalidChild }
        try check(helperNow, locator: helper.stamp.pid, parent: hostNow)
        if let captured = core {
            let coreNow = try backend.stamp(captured.pid)
            try check(coreNow, locator: captured.pid, parent: helperNow)
            guard coreNow == captured else { throw SSIError.invalidChild }
        }
    }
    func bindSupervisor(locatorPID: Int32, launch: UUID, generation: UInt64) throws -> SSISupervisorProof {
        let intent = try capture(launch, generation)
        do {
            let context = try backend.context()
            try verifyHost(context)
            let before = try backend.stamp(locatorPID)
            try check(before, locator: locatorPID, parent: context.host)
            guard try backend.guestUnique(locatorPID, kind: .supervisor) == context.seal.helperStatic.staticUnique,
                  try backend.stamp(locatorPID) == before else { throw SSIError.invalidChild }
            let helper = Helper(intent: intent, context: context, stamp: before)
            try verifyHelper(helper)
            guard try backend.context().seal == context.seal else { throw SSIError.invalidArtifact }
            try finalStamps(helper)
            let token = UUID()
            try commit(intent) { helpers[token] = helper }
            return SSISupervisorProof(token: token)
        } catch { revokeCaptured(intent); throw error }
    }
    private func helper(_ proof: SSISupervisorProof) throws -> Helper {
        lock.lock(); defer { lock.unlock() }
        guard let value = helpers[proof.token], value.intent == active else { throw SSIError.revoked }; return value
    }
    func bindCoreChain(_ proof: SSISupervisorProof, coreLocatorPID: Int32) throws -> SSICoreProof {
        let helper = try helper(proof)
        do {
            guard try backend.context().seal == helper.context.seal else { throw SSIError.invalidArtifact }
            try verifyHelper(helper)
            let before = try backend.stamp(coreLocatorPID)
            try check(before, locator: coreLocatorPID, parent: helper.stamp)
            guard try backend.guestUnique(coreLocatorPID, kind: .core) == helper.context.seal.coreStatic.staticUnique,
                  try backend.stamp(coreLocatorPID) == before else { throw SSIError.invalidChild }
            try verifyHelper(helper)
            guard try backend.context().seal == helper.context.seal else { throw SSIError.invalidArtifact }
            try finalStamps(helper, core: before)
            let token = UUID()
            try commit(helper.intent) {
                guard helpers[proof.token] != nil else { throw SSIError.revoked }
                chains[token] = Chain(helperToken: proof.token, helper: helper, core: before)
            }
            return SSICoreProof(token: token)
        } catch { revokeCaptured(helper.intent); throw error }
    }
    func recheck(_ proof: SSICoreProof) throws {
        lock.lock(); let chain = chains[proof.token]; let intent = active; lock.unlock()
        guard let value = chain, value.helper.intent == intent else { throw SSIError.revoked }
        do {
            guard try backend.context().seal == value.helper.context.seal else { throw SSIError.invalidArtifact }
            try verifyHelper(value.helper)
            let core = try backend.stamp(value.core.pid)
            try check(core, locator: value.core.pid, parent: value.helper.stamp)
            guard core == value.core,
                  try backend.guestUnique(core.pid, kind: .core) == value.helper.context.seal.coreStatic.staticUnique,
                  try backend.stamp(core.pid) == core else { throw SSIError.invalidChild }
            try verifyHelper(value.helper)
            guard try backend.context().seal == value.helper.context.seal else { throw SSIError.invalidArtifact }
            try finalStamps(value.helper, core: value.core)
            try commit(value.helper.intent) {
                guard chains[proof.token] != nil, helpers[value.helperToken] != nil else { throw SSIError.revoked }
            }
        } catch { revokeCaptured(value.helper.intent); throw SSIError.revoked }
    }
    private func revokeCaptured(_ intent: Intent) {
        lock.lock(); defer { lock.unlock() }
        guard active == intent else { return }
        active = nil; helpers.removeAll(); chains.removeAll()
    }
    func revoke(launch: UUID, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let value = active, value.launch == launch, value.generation == generation else { return }
        active = nil; helpers.removeAll(); chains.removeAll()
    }
}
