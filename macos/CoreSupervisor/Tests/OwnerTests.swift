// 只在OWNED_PUBLIC_FIXTURE构建；测试直接调用SupervisorLifecycle生产实现。
final class FakeBackend: LifecycleBackend {
    var now: UInt64 = 1_000_000_000
    let parentPID: Int32 = 400
    let effectiveUID: UInt32 = 501, realUID: UInt32 = 501
    var child: OwnedChild? = OwnedChild(pid: 401, input: 20, output: 21)
    var current: KernelStamp? = KernelStamp(pid: 401, ppid: 400, pgid: 401, uid: 501, ruid: 501, seconds: 9, micros: 1, zombie: false)
    var observations: [ChildObservation] = []
    var fallback: ChildObservation = .running
    var signals: [(Bool, Bool)] = []
    var events: [String] = []
    var reapOK = true, signalOK = true
    var stampAdvanceTo: UInt64?
    var spawnDelay: UInt64 = 0
    var reapCount = 0, spawnCount = 0
    func spawn(_ artifact: SealedCoreArtifact) -> OwnedChild? { spawnCount += 1; now += spawnDelay; events.append("spawn"); return child }
    func observe(_ pid: Int32) -> ChildObservation { events.append("observe"); return observations.isEmpty ? fallback : observations.removeFirst() }
    func stamp(_ pid: Int32) -> KernelStamp? {
        events.append("stamp")
        if let target = stampAdvanceTo { now = target; stampAdvanceTo = nil }
        return current
    }
    func signal(_ pid: Int32, group: Bool, kill: Bool) -> Bool { events.append(kill ? "kill" : "term"); signals.append((group, kill)); return signalOK }
    func reap(_ pid: Int32, expected: ChildObservation) -> Bool { events.append("reap"); reapCount += 1; return reapOK }
    func close(_ fd: Int32) { events.append("close:\(fd)") }
}
@main struct OwnerTests {
    static func started(_ fake: FakeBackend) -> (SupervisorLifecycle, IdentityRequest?) {
        let owner = SupervisorLifecycle(backend: fake)
        return (owner, owner.start(artifact: .publicFixture(), launch: 1, generation: 2))
    }
    static func ready(_ fake: FakeBackend) -> SupervisorLifecycle {
        let (owner, request) = started(fake)
        owner.submit(IdentityResult(request: request!, accepted: true))
        precondition(owner.handshakeCommitted(launch: 1, generation: 2, epoch: 1))
        return owner
    }
    static func main() {
        // 内核读取跨过原5秒期限，submit不得发proof；直接调用生产owner。
        do { let f = FakeBackend(); let (o, request) = started(f); let r = request!
            f.stampAdvanceTo = r.deadline
            o.submit(IdentityResult(request: r, accepted: true))
            precondition(o.snapshot().failure == .timeout && !o.snapshot().proofPermitted,
                "内核核对完成已超期时必须timeout并撤销proof")
        }
        // 正常exit0必须两次WNOWAIT再一次reap，零signal。
        do { let f = FakeBackend(); let o = ready(f); f.events = []; f.fallback = .exited(normal: true, code: 0)
            o.tick(); o.tick(); precondition(f.events.prefix(3).elementsEqual(["observe", "observe", "reap"]))
            precondition(f.reapCount == 1 && f.signals.isEmpty && o.snapshot().confirmedExited && o.snapshot().failure == nil) }
        // 非零退出与signal退出可确认资源完成，保留异常分类。
        for exit in [ChildObservation.exited(normal: true, code: 7), .exited(normal: false, code: 9)] {
            let f = FakeBackend(); let o = ready(f); f.fallback = exit; o.tick()
            precondition(o.snapshot().confirmedExited && o.snapshot().failure == .abnormalExit && f.reapCount == 1)
        }
        // Stop撤销，不等待worker；迟到结果不能恢复ready；拒第二次start。
        do { let f = FakeBackend(); let (o, request) = started(f); o.stop()
            precondition(o.snapshot().identityInFlight && !o.snapshot().proofPermitted && f.events.contains("close:20"))
            o.submit(IdentityResult(request: request!, accepted: true)); precondition(!o.snapshot().proofPermitted && !o.snapshot().identityInFlight)
            precondition(o.start(artifact: .publicFixture(), launch: 3, generation: 4) == nil && f.spawnCount == 1) }
        // spawn时间占用原5秒；core_ready不重置；超期主错在exit0后保留。
        do { let f = FakeBackend(); f.spawnDelay = 5_000_000_000; let (o, request) = started(f)
            precondition(request == nil && o.snapshot().failure == .timeout && o.snapshot().ownsChild) }
        do { let f = FakeBackend(); let (o, request) = started(f); f.now += 4_900_000_000
            o.submit(IdentityResult(request: request!, accepted: true)); precondition(o.snapshot().deadline == 6_000_000_000)
            f.now += 100_000_000; o.tick(); f.fallback = .exited(normal: true, code: 0); o.tick()
            precondition(o.snapshot().confirmedExited && o.snapshot().failure == .timeout) }
        // 错代/epoch结果不释放真正worker，真正迟到结果只释放占位。
        do { let f = FakeBackend(); let (o, request) = started(f); let r = request!
            let wrong = IdentityRequest(launch: 9, generation: r.generation, epoch: r.epoch, deadline: r.deadline, stamp: r.stamp)
            o.submit(IdentityResult(request: wrong, accepted: true)); precondition(o.snapshot().identityInFlight)
            f.now += 5_000_000_000; o.submit(IdentityResult(request: r, accepted: true))
            precondition(o.snapshot().failure == .timeout && !o.snapshot().proofPermitted) }
        // EOF4秒、TERM1秒、KILL2秒；signal成功仍ownsChild，未真实退出超时。
        do { let f = FakeBackend(); let o = ready(f); o.controlEOF(); f.now += 3_999_999_999; o.tick(); precondition(f.signals.isEmpty)
            f.now += 1; o.tick(); precondition(f.signals.count == 1 && f.signals[0].0 && !f.signals[0].1 && o.snapshot().ownsChild)
            f.now += 1_000_000_000; o.tick(); precondition(f.signals.count == 2 && f.signals[1].1)
            f.now += 2_000_000_000; o.tick(); precondition(o.snapshot().failure == .timeout && o.snapshot().ownsChild)
            f.fallback = .exited(normal: false, code: 9); o.tick(); precondition(o.snapshot().confirmedExited && o.snapshot().failure == .timeout)
            let t = f.events.firstIndex(of: "term")!; precondition(f.events[t-2] == "observe" && f.events[t-1] == "stamp") }
        // birth/组/PID/UID/PPID漂移及短读均禁止signal；sticky观察仍可完成真实reap。
        for kind in 0..<6 {
            let f = FakeBackend(); let o = ready(f); o.stop(); let s = f.current!
            f.current = kind == 5 ? nil : KernelStamp(pid: kind == 0 ? 999 : s.pid, ppid: kind == 1 ? 999 : s.ppid,
                pgid: kind == 2 ? 999 : s.pgid, uid: kind == 3 ? 0 : s.uid, ruid: s.ruid,
                seconds: kind == 4 ? 99 : s.seconds, micros: s.micros, zombie: s.zombie)
            f.now += 4_000_000_000; o.tick(); precondition(f.signals.isEmpty && o.snapshot().failure == .kernel)
            f.current = s; o.tick(); precondition(f.signals.isEmpty)
            f.fallback = .exited(normal: true, code: 0); o.tick(); precondition(o.snapshot().confirmedExited && o.snapshot().failure == .kernel)
        }
        // ECHILD/unknown禁止猜测kill；观察恢复只更新退出证据，不清主错。
        do { let f = FakeBackend(); let o = ready(f); f.fallback = .unknown; o.tick(); f.fallback = .running
            f.now += 8_000_000_000; o.tick(); precondition(f.signals.isEmpty && o.snapshot().failure == .observation)
            f.fallback = .exited(normal: true, code: 0); o.tick(); precondition(o.snapshot().confirmedExited && o.snapshot().failure == .observation) }
        // 两次退出证据不一致绝不reap；reap失败绝不重复waitpid。
        do { let f = FakeBackend(); let o = ready(f); f.observations = [.exited(normal: true, code: 0), .exited(normal: true, code: 1)]
            o.tick(); precondition(f.reapCount == 0 && o.snapshot().failure == .observation) }
        do { let f = FakeBackend(); let o = ready(f); f.reapOK = false; f.fallback = .exited(normal: true, code: 0)
            o.tick(); o.tick(); precondition(f.reapCount == 1 && !o.snapshot().confirmedExited && o.snapshot().failure == .reap) }
        // 初始stamp失败仅direct child收尾，保持kernel主错，永不发proof。
        do { let f = FakeBackend(); f.current = nil; let (o, request) = started(f); precondition(request == nil)
            f.now += 4_000_000_000; o.tick(); precondition(f.signals.count == 1 && !f.signals[0].0 && !o.snapshot().proofPermitted)
            f.now += 1_000_000_000; o.tick(); precondition(!f.signals[1].0 && f.signals[1].1)
            f.fallback = .exited(normal: false, code: 9); o.tick(); precondition(o.snapshot().confirmedExited && o.snapshot().failure == .kernel) }
        // 清理signal失败保持首次身份错误，不允许更多signal。
        do { let f = FakeBackend(); let (o, request) = started(f); o.submit(IdentityResult(request: request!, accepted: false))
            f.signalOK = false; f.now += 4_000_000_000; o.tick(); f.now += 9_000_000_000; o.tick()
            precondition(f.signals.count == 1 && o.snapshot().failure == .identity && o.snapshot().ownsChild) }
    }
}
