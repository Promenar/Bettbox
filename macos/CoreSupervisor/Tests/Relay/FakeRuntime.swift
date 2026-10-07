import Foundation
import Dispatch
import Darwin

// 仅独立测试target编译此文件；没有SDK、安全证明或真实子进程回收效力。
struct SealedCoreArtifact { static func prepareSupervisor() throws -> Self {
    if ProcessInfo.processInfo.environment["RELAY_FAKE"] == "late-initial" { usleep(5_200_000) }
    if ProcessInfo.processInfo.environment["RELAY_FAKE"] == "initial-reject" { throw RelayError.invalid }
    return Self()
} }
enum SSIRole { case supervisor }
struct SSIAppleBackend { init(role: SSIRole) {} }
struct SSISupervisorProof {}
struct SSICoreProof {}
final class SSIAuthority {
    init(backend: SSIAppleBackend) {}
    func reserveLaunch(generation: UInt64) throws -> UUID { UUID() }
    func bindSupervisor(locatorPID: Int32, launch: UUID, generation: UInt64) throws -> SSISupervisorProof { SSISupervisorProof() }
    func bindCoreChain(_ proof: SSISupervisorProof, coreLocatorPID: Int32) throws -> SSICoreProof {
        if ProcessInfo.processInfo.environment["RELAY_FAKE"] == "late-core" { usleep(5_200_000) }
        if ProcessInfo.processInfo.environment["RELAY_FAKE"] == "core-reject" { throw RelayError.invalid }
        return SSICoreProof()
    }
    func recheck(_ proof: SSICoreProof) throws {}
    func revoke(launch: UUID, generation: UInt64) {}
}
struct FakeStamp: Equatable { let pid: Int32 }
struct IdentityRequest: Equatable { let launch: UInt64, generation: UInt64, epoch: UInt64, deadline: UInt64; let stamp: FakeStamp }
struct IdentityResult { let request: IdentityRequest; let accepted: Bool }
struct OwnedChild { let pid: Int32, input: Int32, output: Int32 }
final class SystemBackend { var now: UInt64 { DispatchTime.now().uptimeNanoseconds } }
struct FakeSnapshot { let failure: Bool?; let ownsChild: Bool, confirmedExited: Bool, proofPermitted: Bool }
final class SupervisorLifecycle {
    private let lock = NSLock()
    private var child: OwnedChild?
    private var stopped = false, exited = false, proof = false, handshake = false
    private var failed: Bool?
    private var deadline: UInt64 = 0
    private let backend: SystemBackend
    init(backend: SystemBackend) { self.backend = backend }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func start(artifact: SealedCoreArtifact, launch: UInt64, generation: UInt64) -> IdentityRequest? {
        var incoming = [Int32](repeating: -1, count: 2), outgoing = incoming
        guard pipe(&incoming) == 0 else { return nil }
        guard pipe(&outgoing) == 0 else { _ = close(incoming[0]); _ = close(incoming[1]); return nil }
        _ = HRConfigure(incoming[0]); _ = HRConfigure(outgoing[1])
        deadline = backend.now + 5_000_000_000
        child = OwnedChild(pid: getpid(), input: incoming[1], output: outgoing[0])
        let input = incoming[0], output = outgoing[1]
        DispatchQueue.global().async {
            var outputClosed = false
            defer {
                _ = close(input); if !outputClosed { _ = close(output) }
                self.lock.lock(); self.exited = true; self.proof = false; self.lock.unlock()
            }
            var reader = RelayFrameReader()
            var writer = RelayFrameWriter()
            var ack = false
            var businessResult = false
            let fault = ProcessInfo.processInfo.environment["RELAY_FAKE"] ?? "normal"
            while !self.cancelled {
                do {
                    if writer.occupied {
                        if try writer.write(fd: output), businessResult, fault == "hup-while-paused" {
                            _ = close(output); outputClosed = true
                            // 输出HUP发生时fake Core仍存活，隔离owner提前reap路径。
                            while !self.cancelled { usleep(1000) }
                            return
                        }
                    }
                    else if let payload = try reader.read(fd: input, limit: RelayCodec.businessLimit) {
                        if !ack {
                            try RelayCodec.helloOrAck(payload, kind: "hello", generation: generation)
                            try writer.enqueue(RelayCodec.stage("ack", generation)); ack = true
                        } else {
                            businessResult = true
                            try RelayCodec.action(payload, generation: generation)
                            if fault == "counterfeit-credit" { try writer.enqueue(RelayCodec.credit(generation, sequence: 1)) }
                            else if fault == "half-result" {
                                var raw: [UInt8] = [100, 0, 0, 0, 123]
                                _ = HRWrite(output, &raw, raw.count); return
                            } else {
                                let data = ["fullpipe-result", "hup-while-paused"].contains(fault) ? "\"" + String(repeating: "x", count: RelayCodec.businessLimit - 1024) + "\"" : "true"
                                try writer.enqueue(Data("{\"protocol\":1,\"generation\":\(generation),\"result\":{\"id\":\"probe\",\"method\":\"probe\",\"data\":\(data)}}".utf8))
                            }
                        }
                    }
                } catch { return }
                usleep(1000)
            }
        }
        return IdentityRequest(launch: launch, generation: generation, epoch: 1, deadline: deadline, stamp: FakeStamp(pid: getpid()))
    }
    func submit(_ result: IdentityResult) { lock.lock(); defer { lock.unlock() }; if !stopped { proof = result.accepted; if !result.accepted { failed = true } } }
    func relayEndpoints() -> OwnedChild? { lock.lock(); defer { lock.unlock() }; return proof && !stopped ? child : nil }
    func handshakeCommitted(launch: UInt64, generation: UInt64, epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; guard proof, !stopped, backend.now < deadline else { return false }; handshake = true; return true
    }
    func tick() {
        lock.lock(); let timeout = child != nil && !handshake && !stopped && backend.now >= deadline
        if timeout { failed = true }; lock.unlock(); if timeout { stop() }
    }
    func controlEOF() { stop() }
    private func stop() {
        lock.lock(); stopped = true; proof = false
        let input = child?.input; child = child.map { OwnedChild(pid: $0.pid, input: -1, output: $0.output) }; lock.unlock()
        if let input, input >= 0 { _ = close(input) }
    }
    func snapshot() -> FakeSnapshot {
        lock.lock(); defer { lock.unlock() }
        if exited, let child, child.output >= 0 { _ = close(child.output); self.child = OwnedChild(pid: child.pid, input: child.input, output: -1) }
        return FakeSnapshot(failure: failed, ownsChild: child != nil && !exited, confirmedExited: exited, proofPermitted: proof)
    }
}
