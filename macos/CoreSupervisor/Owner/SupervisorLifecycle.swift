import Dispatch

// 身份产物只能由同一封存模块产生；候选没有生产发行器或可绕过身份的main。
struct SealedCoreArtifact {
    let path: String
    private init(path: String) { self.path = path }
    #if OWNED_PUBLIC_FIXTURE
    static func publicFixture() -> Self { Self(path: "public-fixed-stub") }
    #endif
}
struct KernelStamp: Equatable {
    let pid: Int32, ppid: Int32, pgid: Int32
    let uid: UInt32, ruid: UInt32
    let seconds: UInt64, micros: UInt64
    let zombie: Bool
    func sameBirth(as other: Self) -> Bool {
        pid == other.pid && ppid == other.ppid && pgid == other.pgid && uid == other.uid &&
        ruid == other.ruid && seconds == other.seconds && micros == other.micros
    }
}
struct OwnedChild { let pid: Int32, input: Int32, output: Int32 }
enum ChildObservation: Equatable { case running, exited(normal: Bool, code: Int32), unknown }
enum LifecycleFailure: String { case spawn, kernel, identity, timeout, observation, signal, reap, abnormalExit, cancelled }
struct IdentityRequest: Equatable {
    let launch: UInt64, generation: UInt64, epoch: UInt64, deadline: UInt64
    let stamp: KernelStamp
}
// 不序列化SDK身份凭证。worker模块仅返回内部判决，禁止wait/signal/写pipe。
struct IdentityResult { let request: IdentityRequest; let accepted: Bool }
protocol LifecycleBackend: AnyObject {
    var now: UInt64 { get }
    var parentPID: Int32 { get }
    var effectiveUID: UInt32 { get }
    var realUID: UInt32 { get }
    func spawn(_ artifact: SealedCoreArtifact) -> OwnedChild?
    func observe(_ pid: Int32) -> ChildObservation
    func stamp(_ pid: Int32) -> KernelStamp?
    func signal(_ pid: Int32, group: Bool, kill: Bool) -> Bool
    func reap(_ pid: Int32, expected: ChildObservation) -> Bool
    func close(_ fd: Int32)
}
struct LifecycleSnapshot {
    let phase: String
    let failure: LifecycleFailure?
    let ownsChild: Bool
    let confirmedExited: Bool
    let identityInFlight: Bool
    let proofPermitted: Bool
    let deadline: UInt64?
}

// 一个实例只允许一个launch。全部backend调用在同一串行队列，外部没有wait权。
// relay须独立推进非阻塞IO，不能在这些短回调中阻塞或等待Security。
final class SupervisorLifecycle {
    private let queue = DispatchQueue(label: "com.appshub.bettbox.supervisor.owner")
    private let backend: LifecycleBackend
    private var phase = "idle"
    private var failure: LifecycleFailure?
    private var child: OwnedChild?
    private var captured: KernelStamp?
    private var launch: UInt64 = 0, generation: UInt64 = 0, epoch: UInt64 = 0
    private var deadline: UInt64?
    private var stopDeadline: UInt64?
    private var stopStage = 0
    private var inFlight: IdentityRequest?
    private var proof = false, completedHandshake = false, exited = false
    private var reapAttempted = false, inputClosed = false, outputClosed = false
    private var signalAllowed = true
    init(backend: LifecycleBackend) { self.backend = backend }
    private func fail(_ value: LifecycleFailure) { if failure == nil { failure = value } }
    private func add(_ seconds: UInt64) -> UInt64 { backend.now.addingReportingOverflow(seconds * 1_000_000_000).overflow ? UInt64.max : backend.now + seconds * 1_000_000_000 }
    private func valid(_ stamp: KernelStamp, pid: Int32) -> Bool {
        stamp.pid == pid && stamp.ppid == backend.parentPID && stamp.uid == backend.effectiveUID &&
        stamp.ruid == backend.realUID && stamp.seconds > 0 && stamp.micros < 1_000_000 && stamp.pgid == pid
    }
    func start(artifact: SealedCoreArtifact, launch: UInt64, generation: UInt64) -> IdentityRequest? {
        queue.sync {
            guard phase == "idle", launch > 0, generation > 0 else { return nil }
            self.launch = launch; self.generation = generation; epoch = 1
            deadline = add(5); phase = "spawning"
            guard let spawned = backend.spawn(artifact), spawned.pid > 0 else { fail(.spawn); phase = "failed"; return nil }
            child = spawned // spawn成功即移交，不因后续错误释放child归属。
            guard let stamp = backend.stamp(spawned.pid), valid(stamp, pid: spawned.pid) else {
                fail(.kernel); beginStop(); return nil
            }
            captured = stamp
            guard backend.now < deadline! else { fail(.timeout); beginStop(); return nil }
            let request = IdentityRequest(launch: launch, generation: generation, epoch: epoch, deadline: deadline!, stamp: stamp)
            inFlight = request; phase = "verifying"; return request
        }
    }
    func submit(_ result: IdentityResult) {
        queue.sync {
            guard let request = inFlight, result.request == request else { return }
            inFlight = nil // 迟到worker只释放占位，不恢复权限或重置期限。
            guard phase == "verifying", request.launch == launch, request.generation == generation,
                request.epoch == epoch, backend.now < request.deadline else {
                if phase == "verifying" { fail(.timeout); beginStop() }; return
            }
            guard result.accepted, let child, let stamp = backend.stamp(child.pid),
                valid(stamp, pid: child.pid), stamp.sameBirth(as: request.stamp), !stamp.zombie else {
                fail(.identity); beginStop(); return
            }
            // kernel读取也占用同一启动预算；提交proof前必须按原期限复核。
            guard backend.now < request.deadline else { fail(.timeout); beginStop(); return }
            proof = true; phase = "ready"
        }
    }
    // relay仅在已核验ACK实际提交时调用，不能在core_ready时清除5秒预算。
    func handshakeCommitted(launch: UInt64, generation: UInt64, epoch: UInt64) -> Bool {
        queue.sync {
            guard phase == "ready", proof, self.launch == launch, self.generation == generation,
                self.epoch == epoch, let deadline, backend.now < deadline else { return false }
            completedHandshake = true; phase = "running"; return true
        }
    }
    func stop() { queue.sync { if phase != "idle" && !exited { if !completedHandshake { fail(.cancelled) }; beginStop() } } }
    func controlEOF() { stop() }
    private func beginStop() {
        proof = false; epoch &+= 1
        guard let child, !exited else { return }
        if !inputClosed { backend.close(child.input); inputClosed = true }
        if stopDeadline == nil { stopDeadline = add(4); stopStage = 0 }
        phase = "stopping"
    }
    // 调度器必须持续调用tick，不依赖relay流量或worker完成；没有另一个reaper。
    func tick() { queue.sync { advance() } }
    private func advance() {
        guard let child, !exited else { return }
        if !completedHandshake, stopDeadline == nil, let deadline, backend.now >= deadline {
            fail(.timeout); beginStop()
        }
        switch backend.observe(child.pid) {
        case .unknown:
            fail(.observation); signalAllowed = false; beginStop(); return
        case let .exited(normal, code):
            let expected = ChildObservation.exited(normal: normal, code: code)
            guard backend.observe(child.pid) == expected else {
                fail(.observation); signalAllowed = false; beginStop(); return
            }
            if !normal || code != 0 { fail(.abnormalExit) }
            guard !reapAttempted else { return }
            reapAttempted = true
            guard backend.reap(child.pid, expected: expected) else { fail(.reap); signalAllowed = false; beginStop(); return }
            exited = true; proof = false
            if !inputClosed { backend.close(child.input); inputClosed = true }
            if !outputClosed { backend.close(child.output); outputClosed = true }
            phase = failure == nil ? "exited" : "exitedWithFailure"
            return
        case .running: break
        }
        guard let stopDeadline, backend.now >= stopDeadline, signalAllowed else { return }
        guard stopStage < 2 else { fail(.timeout); signalAllowed = false; return }
        // 每次signal前独立WNOWAIT及实际kernel出生复核；只允许捕获的自己child组。
        switch backend.observe(child.pid) {
        case .running: break
        case .unknown: fail(.observation); signalAllowed = false; return
        case .exited: return
        }
        if let captured {
            guard let current = backend.stamp(child.pid), valid(current, pid: child.pid),
                current.sameBirth(as: captured), !current.zombie else {
                fail(.kernel); signalAllowed = false; return
            }
        }
        // 初始stamp失败时只用spawn返回+成功WNOWAIT保护未reap直接child，禁止group/proof。
        guard !reapAttempted, backend.signal(child.pid, group: captured != nil, kill: stopStage == 1) else {
            fail(.signal); signalAllowed = false; return
        }
        stopStage += 1; self.stopDeadline = add(stopStage == 1 ? 1 : 2)
    }
    func snapshot() -> LifecycleSnapshot {
        queue.sync { LifecycleSnapshot(phase: phase, failure: failure, ownsChild: child != nil && !exited,
            confirmedExited: exited, identityInFlight: inFlight != nil, proofPermitted: proof,
            deadline: deadline) }
    }
}
