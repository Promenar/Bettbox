import Darwin
// 此模块用-import-objc-header OwnedBackend.h编译，没有Foundation Process或SIGCHLD handler。
final class SystemBackend: LifecycleBackend {
    #if OWNED_PUBLIC_FIXTURE
    private let fixture: Int32
    init(publicFixture: Int32) { fixture = publicFixture }
    #else
    init() {}
    #endif
    var now: UInt64 { OCMonotonicNanos() }
    var parentPID: Int32 { OCSelfPID() }
    var effectiveUID: UInt32 { OCSelfUID() }
    var realUID: UInt32 { OCSelfRealUID() }
    func spawn(_ artifact: SealedCoreArtifact) -> OwnedChild? {
        do { try artifact.recheckForSpawn() } catch { return nil }
        var result = OCChild(pid: -1, input_writer: -1, output_reader: -1)
        #if OWNED_PUBLIC_FIXTURE
        let error = OCSpawnPublicFixture(fixture, &result)
        #else
        let error = artifact.path.withCString { OCSpawnSealed($0, &result) }
        #endif
        guard error == OC_OK else { return nil }
        return OwnedChild(pid: result.pid, input: result.input_writer, output: result.output_reader)
    }
    func observe(_ pid: Int32) -> ChildObservation {
        let value = OCObserve(pid)
        if value.state == 0 { return .running }
        if value.state == 1 { return .exited(normal: value.normal != 0, code: value.code) }
        return .unknown
    }
    func stamp(_ pid: Int32) -> KernelStamp? {
        var value = OCStamp()
        guard OCReadStamp(pid, &value) == OC_OK else { return nil }
        return KernelStamp(pid: value.pid, ppid: value.ppid, pgid: value.pgid, uid: value.uid,
            ruid: value.ruid, seconds: value.seconds, micros: value.micros, zombie: value.zombie != 0)
    }
    func signal(_ pid: Int32, group: Bool, kill: Bool) -> Bool { OCSignal(pid, group ? 1 : 0, kill ? SIGKILL : SIGTERM) == OC_OK }
    func reap(_ pid: Int32, expected: ChildObservation) -> Bool {
        guard case let .exited(normal, code) = expected else { return false }
        let value = OCObservation(state: 1, pid: pid, normal: normal ? 1 : 0, code: code)
        return OCReap(pid, value) == OC_OK
    }
    func close(_ fd: Int32) { OCClose(fd) }
}
