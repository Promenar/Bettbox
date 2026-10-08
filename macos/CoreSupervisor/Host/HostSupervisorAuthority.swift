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

private final class HostProxyLease {
    private let lock = NSLock()
    private var current = true
    func isCurrent() -> Bool { lock.lock(); defer { lock.unlock() }; return current }
    func invalidate() { lock.lock(); current = false; lock.unlock() }
}

private struct HostOwnedEndpoint: Equatable {
    let generation: UInt64
    let listenerEpoch: UInt64
    let host: String
    let port: Int
    let state: String
    let bypass: [String]
}

private final class HostProxyStartContext {
    let capability: CredentialBlindEndpointCapability
    let endpoint: HostOwnedEndpoint
    let lease: HostProxyLease
    init(_ capability: CredentialBlindEndpointCapability, _ endpoint: HostOwnedEndpoint, _ lease: HostProxyLease) {
        self.capability = capability; self.endpoint = endpoint; self.lease = lease
    }
}

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
        var lastListenerEpoch: UInt64 = 0
        var endpoint: HostOwnedEndpoint?
        var proxyLease: HostProxyLease?
        var activeProxyResult: SafeResult?
        init(_ launch: UUID, _ generation: UInt64) { self.launch = launch; self.generation = generation }
    }
    private enum ColdState { case pending, clear, blocked }
    private let state = DispatchQueue(label: "bettbox.supervisor.host.intent")
    private let worker = DispatchQueue(label: "bettbox.supervisor.host.sdk")
    private let replyQueue: DispatchQueue
    private let facts: SSIHostFacts, authority: SSIHostProofAuthority
    private let proxy: HostSystemProxyCoordinating
    private let deadline: TimeInterval
    private var ticket: Ticket?
    private var busy: UUID?
    private var timer: DispatchSourceTimer?
    private var coldState: ColdState = .pending
    private var preparationComplete = false
    private var pendingReserve: (generation: UInt64, reply: Reply)?
    private var proxyOperation: UUID?
    private var pendingProxyStarts: Set<UUID> = []
    private var proxyClear = false
    init(facts: SSIHostFacts, authority: SSIHostProofAuthority, proxy: HostSystemProxyCoordinating,
         replyQueue: DispatchQueue = .main,
         deadline: TimeInterval = 5) {
        self.facts = facts; self.authority = authority; self.proxy = proxy
        self.replyQueue = replyQueue; self.deadline = deadline
        proxy.prepare { [weak self] result in
            self?.state.async { [weak self] in self?.finishColdPreparation(result) }
        }
    }
    private func respond(_ reply: @escaping Reply, _ value: Result<Any?, HostSupervisorFailure>) {
        replyQueue.async { reply(value) }
    }
    private func fail(_ code: String) throws -> Never { throw HostSupervisorFailure(code: code) }
    private func revoke(_ value: Ticket) {
        value.proxyLease?.invalidate()
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

    private func safe(_ result: SafeResult) -> Bool {
        (result.status == .idle || result.status == .restored) && result.unresolvedGroups == 0
    }

    private func wire(_ result: SafeResult) throws -> [String: Any] {
        guard result.generation <= UInt64(Int64.max), result.changedGroups >= 0,
              result.unresolvedGroups >= 0 else { try fail("system_proxy_recovery_required") }
        return [
            "status": result.status.rawValue,
            "transactionGeneration": Int64(result.generation),
            "changedGroups": Int64(result.changedGroups),
            "unresolvedGroups": Int64(result.unresolvedGroups),
        ]
    }

    private func finishColdPreparation(_ result: SafeResult) {
        preparationComplete = true
        coldState = safe(result) ? .clear : .blocked
        proxyClear = safe(result)
        guard let pending = pendingReserve else { return }
        pendingReserve = nil
        if safe(result) {
            do { try beginReserve(generation: pending.generation, reply: pending.reply) }
            catch let error as HostSupervisorFailure { respond(pending.reply, .failure(error)) }
            catch { respond(pending.reply, .failure(HostSupervisorFailure(code: "identity_failed"))) }
        } else {
            respond(pending.reply, .failure(HostSupervisorFailure(code: "system_proxy_recovery_required")))
        }
    }

    private func beginReserve(generation: UInt64, reply: @escaping Reply) throws {
        guard case .clear = coldState else { try fail("system_proxy_recovery_required") }
        guard proxyClear, proxyOperation == nil, pendingProxyStarts.isEmpty else {
            try fail("system_proxy_recovery_required")
        }
        guard busy == nil else { try fail("sdk_busy") }
        guard ticket == nil || ticket!.stopped else { try fail("stop_unconfirmed") }
        let value = Ticket(try authority.reserveLaunch(generation: generation), generation); ticket = value
        try sdk(value, reply: reply, reservation: true, run: { try self.facts.verifiedHelperForHost() }, commit: { raw in
            guard let descriptor = raw as? SSIHostHelperDescriptor, !descriptor.path.isEmpty else {
                try self.fail("identity_failed")
            }
            value.descriptor = descriptor
            return ["launch": value.launch.uuidString.lowercased(), "generation": value.generation, "path": descriptor.path]
        })
    }

    private func bypass(_ raw: Any?) throws -> [String] {
        guard let values = raw as? [Any], values.count <= 256 else { try fail("invalid_arguments") }
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let string = value as? String else { try fail("invalid_arguments") }
            result.append(string)
        }
        guard ProxyIntent(port: 1, bypass: result).validate() else { try fail("invalid_arguments") }
        return result
    }

    private func endpoint(_ fields: [String: Any], ticket value: Ticket) throws -> HostOwnedEndpoint {
        let generation = UInt64(try integer(fields["generation"], maximum: Int64.max))
        let listenerEpoch = UInt64(try integer(fields["listenerEpoch"], maximum: Int64.max))
        let port = Int(try integer(fields["port"], maximum: 65535))
        guard generation == value.generation else { try fail("stale") }
        guard fields["host"] as? String == "127.0.0.1",
              fields["state"] as? String == "active" else { try fail("invalid_arguments") }
        return HostOwnedEndpoint(generation: generation, listenerEpoch: listenerEpoch,
                                 host: "127.0.0.1", port: port, state: "active",
                                 bypass: try bypass(fields["bypass"]))
    }

    private func beginActivation(_ fields: [String: Any], reply: @escaping Reply) throws {
        guard case .clear = coldState, proxyOperation == nil, pendingProxyStarts.isEmpty else {
            try fail("system_proxy_recovery_required")
        }
        let value = try handle(fields["handle"], core: true)
        let candidate = try endpoint(fields, ticket: value)
        guard !value.revoked, let proof = value.coreProof else { try fail("revoked") }
        if let current = value.endpoint {
            if current == candidate, value.lastListenerEpoch == candidate.listenerEpoch,
               value.proxyLease?.isCurrent() == true, value.activeProxyResult?.status == .applied,
               let cached = value.activeProxyResult {
                respond(reply, .success(try wire(cached))); return
            }
            try fail(candidate.listenerEpoch <= value.lastListenerEpoch ? "stale" : "stop_unconfirmed")
        }
        guard proxyClear else { try fail("system_proxy_recovery_required") }
        guard candidate.listenerEpoch > value.lastListenerEpoch else { try fail("stale") }

        let operation = UUID(); proxyOperation = operation
        do {
            try sdk(value, reply: { [weak self, weak value] checked in
                guard let self, let value else { return }
                self.state.async { [self, value] in
                    switch checked {
                    case .failure(let error):
                        if self.proxyOperation == operation { self.proxyOperation = nil }
                        self.respond(reply, .failure(error))
                    case .success(let raw):
                        guard self.proxyOperation == operation, self.ticket === value, !value.revoked,
                              let context = raw as? HostProxyStartContext,
                              context.lease.isCurrent(), value.endpoint == context.endpoint else {
                            self.contextLease(raw)?.invalidate()
                            if self.proxyOperation == operation { self.proxyOperation = nil }
                            self.respond(reply, .failure(HostSupervisorFailure(code: "revoked"))); return
                        }
                        self.pendingProxyStarts.insert(operation)
                        self.proxy.start(context.capability) { [weak self, value] result in
                            self?.state.async { [weak self, value] in
                                guard let self else { return }
                                self.pendingProxyStarts.remove(operation)
                                guard self.proxyOperation == operation, self.ticket === value,
                                      value.endpoint == context.endpoint else {
                                    context.lease.invalidate()
                                    value.activeProxyResult = nil
                                    if result.status == .applied || result.status == .recoveryRequired {
                                        self.proxyClear = false; self.coldState = .blocked
                                        self.respond(reply, .failure(HostSupervisorFailure(code: "system_proxy_recovery_required")))
                                    } else {
                                        self.respond(reply, .failure(HostSupervisorFailure(code: "revoked")))
                                    }
                                    return
                                }
                                self.proxyOperation = nil
                                if result.status == .applied && context.lease.isCurrent() {
                                    value.activeProxyResult = result
                                } else {
                                    context.lease.invalidate(); value.activeProxyResult = nil
                                }
                                self.proxyClear = false
                                do { self.respond(reply, .success(try self.wire(result))) }
                                catch let error as HostSupervisorFailure { self.respond(reply, .failure(error)) }
                                catch { self.respond(reply, .failure(HostSupervisorFailure(code: "system_proxy_recovery_required"))) }
                            }
                        }
                    }
                }
            }, run: {
                try self.authority.recheck(proof); return true
            }, commit: { _ in
                guard self.proxyOperation == operation, self.ticket === value, !value.revoked,
                      value.coreHandle == (fields["handle"] as? String),
                      value.coreProof != nil, let descriptor = value.descriptor,
                      let helper = value.helper, let core = value.core,
                      case .present(let hostNow) = self.facts.kernelRead(descriptor.context.host.pid),
                      hostNow == descriptor.context.host,
                      try self.child(helper.pid, parent: hostNow) == helper,
                      try self.child(core.pid, parent: helper) == core else { try self.fail("identity_failed") }
                let lease = HostProxyLease()
                guard let capability = CredentialBlindEndpointCapability(
                    supervisorGeneration: candidate.generation, listenerEpoch: candidate.listenerEpoch,
                    host: candidate.host, port: candidate.port, state: candidate.state,
                    bypass: candidate.bypass, current: { [weak lease] in lease?.isCurrent() == true }) else {
                    try self.fail("invalid_arguments")
                }
                value.lastListenerEpoch = candidate.listenerEpoch
                value.endpoint = candidate; value.proxyLease = lease; value.activeProxyResult = nil
                self.proxyClear = false
                return HostProxyStartContext(capability, candidate, lease)
            })
        } catch {
            if proxyOperation == operation { proxyOperation = nil }
            throw error
        }
    }

    private func contextLease(_ raw: Any?) -> HostProxyLease? {
        (raw as? HostProxyStartContext)?.lease
    }

    private func clearProxyResponsibility(_ value: Ticket?) {
        value?.proxyLease?.invalidate()
        value?.proxyLease = nil; value?.endpoint = nil; value?.activeProxyResult = nil
        proxyClear = true; coldState = .clear
    }

    private func finishRecovery(_ result: SafeResult, operation: UUID, value: Ticket?,
                                reply: @escaping Reply, nilOnSuccess: Bool) {
        guard proxyOperation == operation else {
            respond(reply, .failure(HostSupervisorFailure(code: "system_proxy_recovery_required"))); return
        }
        proxyOperation = nil
        let settled = pendingProxyStarts.isEmpty
        let effectiveSafe = safe(result) && settled
        if effectiveSafe { clearProxyResponsibility(value) }
        else { proxyClear = false; coldState = .blocked }
        if nilOnSuccess {
            if effectiveSafe { respond(reply, .success(nil)) }
            else { respond(reply, .failure(HostSupervisorFailure(code: "system_proxy_recovery_required"))) }
            return
        }
        let reported = safe(result) && !settled
            ? SafeResult(status: .recoveryRequired, generation: result.generation,
                         changedGroups: result.changedGroups, unresolvedGroups: result.unresolvedGroups)
            : result
        do { respond(reply, .success(try wire(reported))) }
        catch let error as HostSupervisorFailure { respond(reply, .failure(error)) }
        catch { respond(reply, .failure(HostSupervisorFailure(code: "system_proxy_recovery_required"))) }
    }

    private func beginRestore(_ value: Ticket, generation: UInt64, listenerEpoch: UInt64,
                              reply: @escaping Reply, nilOnSuccess: Bool = false) throws {
        guard generation == value.generation, listenerEpoch == value.endpoint?.listenerEpoch else { try fail("stale") }
        value.proxyLease?.invalidate(); proxyClear = false
        let operation = UUID(); proxyOperation = operation
        proxy.restore { [weak self, weak value] result in
            self?.state.async { [weak self, weak value] in
                guard let self else { return }
                finishRecovery(result, operation: operation, value: value, reply: reply, nilOnSuccess: nilOnSuccess)
            }
        }
    }

    private func beginRecovery(reply: @escaping Reply) throws {
        let value = ticket
        value?.proxyLease?.invalidate(); proxyClear = false; coldState = .pending
        let operation = UUID(); proxyOperation = operation
        proxy.recover { [weak self, weak value] result in
            self?.state.async { [weak self, weak value] in
                guard let self else { return }
                finishRecovery(result, operation: operation, value: value, reply: reply, nilOnSuccess: false)
            }
        }
    }
    func call(_ method: String, arguments: Any?, reply: @escaping Reply) {
        state.async { [self] in
            do {
                switch method {
                case "reserveSupervisorLaunch":
                    let fields = try dictionary(arguments, ["generation"])
                    let generation = UInt64(try integer(fields["generation"], maximum: Int64.max))
                    switch coldState {
                    case .pending:
                        guard !preparationComplete else { try fail("system_proxy_recovering") }
                        guard pendingReserve == nil else { try fail("system_proxy_recovering") }
                        pendingReserve = (generation, reply)
                    case .blocked: try fail("system_proxy_recovery_required")
                    case .clear: try beginReserve(generation: generation, reply: reply)
                    }
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
                case "activateOwnedSystemProxy":
                    let fields = try dictionary(arguments,
                        ["handle", "generation", "listenerEpoch", "host", "port", "state", "bypass"])
                    try beginActivation(fields, reply: reply)
                case "restoreSystemProxy":
                    let fields = try dictionary(arguments, ["generation", "listenerEpoch"])
                    let generation = UInt64(try integer(fields["generation"], maximum: Int64.max))
                    let listenerEpoch = UInt64(try integer(fields["listenerEpoch"], maximum: Int64.max))
                    guard let value = ticket, value.endpoint != nil else { try fail("stale") }
                    try beginRestore(value, generation: generation, listenerEpoch: listenerEpoch, reply: reply)
                case "recoverSystemProxy":
                    _ = try dictionary(arguments, [])
                    guard preparationComplete else { try fail("system_proxy_recovering") }
                    try beginRecovery(reply: reply)
                case "revokeLaunch":
                    let fields = try dictionary(arguments, ["launch", "generation"]), value = try matching(fields)
                    revoke(value)
                    if let endpoint = value.endpoint {
                        try beginRestore(value, generation: value.generation, listenerEpoch: endpoint.listenerEpoch,
                                         reply: reply, nilOnSuccess: true)
                    } else if proxyClear {
                        respond(reply, .success(nil))
                    } else {
                        respond(reply, .failure(HostSupervisorFailure(code: "system_proxy_recovery_required")))
                    }
                case "confirmPreflightStopped":
                    let fields = try dictionary(arguments, ["generation"])
                    let generation = UInt64(try integer(fields["generation"], maximum: Int64.max))
                    // 未发行reservation的SDK已终止并内部撤销，才能证明预检无进程所有权。
                    let stopped = busy == nil && proxyOperation == nil && pendingProxyStarts.isEmpty &&
                        proxyClear && ticket.map { value in
                        value.generation == generation && value.revoked && value.stopped &&
                        !value.issuedReservation && value.helper == nil && value.core == nil &&
                        !value.helperProofEverIssued && !value.coreAttempted
                    } == true
                    respond(reply, .success(stopped))
                case "confirmStopped":
                    let fields = try dictionary(arguments, ["launch", "generation"]), value = try matching(fields)
                    let stopped = busy == nil && proxyOperation == nil && pendingProxyStarts.isEmpty &&
                        proxyClear && value.endpoint == nil && value.revoked &&
                        value.helper.map(gone) == true &&
                        (!(value.coreAttempted || value.helperProofEverIssued) || value.core.map(gone) == true)
                    value.stopped = stopped; respond(reply, .success(stopped))
                default: try fail("unknown_method")
                }
            } catch let error as HostSupervisorFailure { respond(reply, .failure(error)) }
            catch { respond(reply, .failure(HostSupervisorFailure(code: "identity_failed"))) }
        }
    }
}
