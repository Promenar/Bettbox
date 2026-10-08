import Foundation
import CoreFoundation

// 接入方仅能从固定 host 角色发行此描述符；heldFD 必须拥有已封存文件的生命周期。
protocol SSIHostHelperDescriptor: AnyObject {
    var path: String { get }
    var context: SSIContext { get }
    var heldFD: AnyObject { get }
}
enum SSIHostKernelRead { case present(SSIStamp), absent, unknown }
protocol SSIHostFacts {
    func verifiedHelperForHost() throws -> SSIHostHelperDescriptor
    func kernelRead(_ pid: Int32) -> SSIHostKernelRead
}
// 生产使用真实 SSIAuthority；此协议仅让独立测试注入故障与延迟。
protocol SSIHostProofAuthority {
    func reserveLaunch(generation: UInt64) throws -> UUID
    func bindSupervisor(locatorPID: Int32, launch: UUID, generation: UInt64) throws -> SSISupervisorProof
    func bindCoreChain(_ proof: SSISupervisorProof, coreLocatorPID: Int32) throws -> SSICoreProof
    func recheck(_ proof: SSICoreProof) throws
    func revoke(launch: UUID, generation: UInt64)
}
extension SSIAuthority: SSIHostProofAuthority {}
struct HostSupervisorFailure: Error { let code: String }

final class HostSupervisorAuthority {
    typealias Reply = (Result<Any?, HostSupervisorFailure>) -> Void
    private final class Ticket {
        let launch: UUID, generation: UInt64
        var descriptor: SSIHostHelperDescriptor?
        var helper: SSIStamp?, core: SSIStamp?
        var helperHandle: String?, coreHandle: String?
        var helperProof: SSISupervisorProof?, coreProof: SSICoreProof?
        var revoked = false, stopped = false, coreAttempted = false
        var issuedReservation = false, helperProofEverIssued = false
        init(_ launch: UUID, _ generation: UInt64) { self.launch = launch; self.generation = generation }
    }
    private let state = DispatchQueue(label: "bettbox.supervisor.host.intent")
    private let worker = DispatchQueue(label: "bettbox.supervisor.host.sdk")
    private let replyQueue: DispatchQueue
    private let facts: SSIHostFacts, authority: SSIHostProofAuthority
    private let deadline: TimeInterval
    private var ticket: Ticket?
    private var busy: UUID?
    private var timer: DispatchSourceTimer?
    init(facts: SSIHostFacts, authority: SSIHostProofAuthority, replyQueue: DispatchQueue = .main,
         deadline: TimeInterval = 5) {
        self.facts = facts; self.authority = authority; self.replyQueue = replyQueue; self.deadline = deadline
    }
    private func respond(_ reply: @escaping Reply, _ value: Result<Any?, HostSupervisorFailure>) {
        replyQueue.async { reply(value) }
    }
    private func fail(_ code: String) throws -> Never { throw HostSupervisorFailure(code: code) }
    private func revoke(_ value: Ticket) {
        value.revoked = true; value.helperProof = nil; value.coreProof = nil
        authority.revoke(launch: value.launch, generation: value.generation)
    }
    // timer 先撤权再回包；worker 尚未退出时 busy 不释放，不建立 SDK 等待队列。
    private func sdk(_ value: Ticket, reply: @escaping Reply, reservation: Bool = false,
                     run: @escaping () throws -> Any, commit: @escaping (Any) throws -> Any?) throws {
        guard busy == nil else { try fail("sdk_busy") }
        let job = UUID(); busy = job
        let expires = DispatchTime.now().uptimeNanoseconds + UInt64(deadline * 1_000_000_000)
        var replied = false
        let deadlineTimer = DispatchSource.makeTimerSource(queue: state)
        timer = deadlineTimer
        deadlineTimer.schedule(deadline: .now() + deadline)
        deadlineTimer.setEventHandler { [self] in
            guard busy == job, !replied else { return }
            replied = true; revoke(value); respond(reply, .failure(HostSupervisorFailure(code: "timeout")))
            deadlineTimer.cancel(); deadlineTimer.setEventHandler {}; timer = nil
        }
        deadlineTimer.resume()
        worker.async { [self] in
            let outcome = Result { try run() }
            state.async { [self] in
                guard busy == job else { return }
                busy = nil; deadlineTimer.cancel(); deadlineTimer.setEventHandler {}; timer = nil
                guard !replied else {
                    if !value.issuedReservation { value.stopped = true }
                    return
                }
                replied = true
                guard DispatchTime.now().uptimeNanoseconds < expires else {
                    revoke(value); if !value.issuedReservation { value.stopped = true }
                    respond(reply, .failure(HostSupervisorFailure(code: "timeout"))); return
                }
                guard ticket === value, !value.revoked else {
                    if !value.issuedReservation { value.stopped = true }
                    respond(reply, .failure(HostSupervisorFailure(code: "revoked"))); return
                }
                do {
                    let result = try commit(outcome.get())
                    // commit的内核读取也消耗原预算；未回包不得先认作已发行。
                    guard DispatchTime.now().uptimeNanoseconds < expires else {
                        revoke(value); if !value.issuedReservation { value.stopped = true }
                        respond(reply, .failure(HostSupervisorFailure(code: "timeout"))); return
                    }
                    if reservation { value.issuedReservation = true }
                    if value.helperProof != nil { value.helperProofEverIssued = true }
                    respond(reply, .success(result))
                }
                catch {
                    revoke(value); if !value.issuedReservation { value.stopped = true }
                    respond(reply, .failure(HostSupervisorFailure(code: "identity_failed")))
                }
            }
        }
    }
    private func dictionary(_ raw: Any?, _ fields: Set<String>) throws -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys) == fields else { try fail("invalid_arguments") }
        return value
    }
    private func integer(_ raw: Any?, maximum: Int64) throws -> Int64 {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["s", "i", "l", "q", "S", "I", "L", "Q", "c", "C"].contains(String(cString: number.objCType)),
              let result = Int64(number.stringValue), result > 0, result <= maximum else { try fail("invalid_arguments") }
        return result
    }
    private func uuid(_ raw: Any?) throws -> UUID {
        guard let string = raw as? String, let value = UUID(uuidString: string),
              value.uuidString.lowercased() == string else { try fail("invalid_arguments") }
        return value
    }
    private func matching(_ fields: [String: Any]) throws -> Ticket {
        let launch = try uuid(fields["launch"]), generation = try integer(fields["generation"], maximum: Int64.max)
        guard let value = ticket, value.launch == launch, value.generation == UInt64(generation) else { try fail("stale") }
        return value
    }
    private func handle(_ raw: Any?, core: Bool) throws -> Ticket {
        _ = try uuid(raw)
        guard let string = raw as? String, let value = ticket,
              string == (core ? value.coreHandle : value.helperHandle) else { try fail("stale") }
        return value
    }
    private func child(_ pid: Int32, parent: SSIStamp) throws -> SSIStamp {
        guard case .present(let stamp) = facts.kernelRead(pid), stamp.pid == pid, stamp.parent == parent.pid,
              stamp.effectiveUID == parent.effectiveUID, stamp.realUID == parent.realUID,
              stamp.birthSeconds > 0, stamp.birthMicros < 1_000_000 else { try fail("kernel_unknown") }
        return stamp
    }
    private func gone(_ stamp: SSIStamp) -> Bool {
        switch facts.kernelRead(stamp.pid) {
        case .absent: return true
        case .unknown: return false
        case .present(let current):
            // 相同 PID 不同出生已证明记录中的进程消失；不能只比较 UID 或 PPID。
            return current.pid == stamp.pid && (current.birthSeconds != stamp.birthSeconds || current.birthMicros != stamp.birthMicros)
        }
    }
    func call(_ method: String, arguments: Any?, reply: @escaping Reply) {
        state.async { [self] in
            do {
                switch method {
                case "reserveSupervisorLaunch":
                    let fields = try dictionary(arguments, ["generation"])
                    let generation = UInt64(try integer(fields["generation"], maximum: Int64.max))
                    guard busy == nil else { try fail("sdk_busy") }
                    guard ticket == nil || ticket!.stopped else { try fail("stop_unconfirmed") }
                    let value = Ticket(try authority.reserveLaunch(generation: generation), generation); ticket = value
                    try sdk(value, reply: reply, reservation: true, run: { try self.facts.verifiedHelperForHost() }, commit: { raw in
                        guard let descriptor = raw as? SSIHostHelperDescriptor, !descriptor.path.isEmpty else { try self.fail("identity_failed") }
                        value.descriptor = descriptor
                        return ["launch": value.launch.uuidString.lowercased(), "generation": value.generation, "path": descriptor.path]
                    })
                case "bindSupervisor":
                    let fields = try dictionary(arguments, ["launch", "generation", "pid"])
                    let value = try matching(fields), pid = Int32(try integer(fields["pid"], maximum: Int64(Int32.max)))
                    guard let descriptor = value.descriptor else { try fail("identity_failed") }
                    let stamp = try child(pid, parent: descriptor.context.host)
                    guard value.helper == nil || value.helper == stamp else { try fail("stale") }
                    value.helper = stamp
                    guard !value.revoked else { try fail("revoked") }
                    guard value.helperProof == nil else { try fail("already_bound") }
                    try sdk(value, reply: reply, run: { try self.authority.bindSupervisor(locatorPID: pid, launch: value.launch, generation: value.generation) }, commit: { raw in
                        guard let proof = raw as? SSISupervisorProof,
                              try self.child(pid, parent: descriptor.context.host) == stamp else { try self.fail("identity_failed") }
                        value.helperProof = proof; value.helperHandle = UUID().uuidString.lowercased()
                        return ["handle": value.helperHandle!, "generation": value.generation]
                    })
                case "bindCoreChain":
                    let fields = try dictionary(arguments, ["handle", "pid"])
                    let value = try handle(fields["handle"], core: false)
                    let pid = Int32(try integer(fields["pid"], maximum: Int64(Int32.max)))
                    value.coreAttempted = true
                    guard let helper = value.helper else { try fail("kernel_unknown") }
                    let stamp = try child(pid, parent: helper)
                    guard value.core == nil || value.core == stamp else { try fail("stale") }
                    value.core = stamp
                    guard !value.revoked, let proof = value.helperProof else { try fail("revoked") }
                    guard value.coreProof == nil else { try fail("already_bound") }
                    try sdk(value, reply: reply, run: { try self.authority.bindCoreChain(proof, coreLocatorPID: pid) }, commit: { raw in
                        guard let coreProof = raw as? SSICoreProof,
                              case .present(let helperNow) = self.facts.kernelRead(helper.pid), helperNow == helper,
                              try self.child(pid, parent: helper) == stamp else { try self.fail("identity_failed") }
                        value.coreProof = coreProof; value.coreHandle = UUID().uuidString.lowercased()
                        return ["handle": value.coreHandle!, "generation": value.generation]
                    })
                case "recheckCoreChain":
                    let fields = try dictionary(arguments, ["handle"]), value = try handle(fields["handle"], core: true)
                    guard !value.revoked, let proof = value.coreProof else { try fail("revoked") }
                    try sdk(value, reply: reply, run: { try self.authority.recheck(proof); return true }, commit: { _ in
                        guard let descriptor = value.descriptor, let helper = value.helper, let core = value.core,
                              case .present(let hostNow) = self.facts.kernelRead(descriptor.context.host.pid), hostNow == descriptor.context.host,
                              try self.child(helper.pid, parent: hostNow) == helper,
                              try self.child(core.pid, parent: helper) == core else { try self.fail("identity_failed") }
                        return ["valid": true, "generation": value.generation]
                    })
                case "revokeLaunch":
                    let fields = try dictionary(arguments, ["launch", "generation"]), value = try matching(fields)
                    revoke(value); respond(reply, .success(nil))
                case "confirmPreflightStopped":
                    let fields = try dictionary(arguments, ["generation"])
                    let generation = UInt64(try integer(fields["generation"], maximum: Int64.max))
                    // 未发行reservation的SDK已终止并内部撤销，才能证明预检无进程所有权。
                    let stopped = busy == nil && ticket.map { value in
                        value.generation == generation && value.revoked && value.stopped &&
                        !value.issuedReservation && value.helper == nil && value.core == nil &&
                        !value.helperProofEverIssued && !value.coreAttempted
                    } == true
                    respond(reply, .success(stopped))
                case "confirmStopped":
                    let fields = try dictionary(arguments, ["launch", "generation"]), value = try matching(fields)
                    let stopped = value.revoked && value.helper.map(gone) == true && (!(value.coreAttempted || value.helperProofEverIssued) || value.core.map(gone) == true)
                    value.stopped = stopped; respond(reply, .success(stopped))
                default: try fail("unknown_method")
                }
            } catch let error as HostSupervisorFailure { respond(reply, .failure(error)) }
            catch { respond(reply, .failure(HostSupervisorFailure(code: "identity_failed"))) }
        }
    }
}
