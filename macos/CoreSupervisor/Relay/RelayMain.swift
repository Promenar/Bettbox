import Foundation
import Darwin

private enum RelayPhase { case preparing, coreIdentity, hello, writingHello, ack, publishingAck, business }
private enum HostFrame { case ready, coreReady, ack, result, credit }

// 唯一owner持有Core FD、signal及reaper；relay只借用已获proof的端点。
func runSupervisorRelay(arguments: [String]) -> Int32 {
    let generation: UInt64
    do { generation = try RelayCodec.arguments(arguments) } catch { return 31 }
    HRIgnorePipeSignal()
    guard HRConfigure(STDIN_FILENO) == 0, HRConfigure(STDOUT_FILENO) == 0 else { return 31 }
    let backend = SystemBackend()
    let owner = SupervisorLifecycle(backend: backend)
    let authority = SSIAuthority(backend: SSIAppleBackend(role: .supervisor))
    let mailbox = SDKMailbox()
    let sdkLaunch: UUID
    do { sdkLaunch = try authority.reserveLaunch(generation: generation) } catch { return 31 }
    let initialStart = backend.now
    let initialDeadline = initialStart > UInt64.max - 5_000_000_000 ? UInt64.max : initialStart + 5_000_000_000
    guard mailbox.launch({
        do {
            let artifact = try SealedCoreArtifact.prepareSupervisor()
            let proof = try authority.bindSupervisor(locatorPID: getpid(), launch: sdkLaunch, generation: generation)
            return .prepared(artifact, proof)
        } catch { return .rejected }
    }) else { return 31 }
    var phase = RelayPhase.preparing
    var artifact: SealedCoreArtifact?
    var helperProof: SSISupervisorProof?
    var wireLaunch: UUID?
    var request: IdentityRequest?
    var endpoint: OwnedChild?
    var hostReader = RelayFrameReader(), coreReader = RelayFrameReader()
    var hostWriter = RelayFrameWriter(), coreWriter = RelayFrameWriter()
    var hostFrame = HostFrame.ready
    var readySent = false, coreReadySent = false, stopping = false
    var localFailure: Int32 = 0
    var sequence: UInt64 = 0
    var creditPending: Data?
    var hostPermission = false
    var coreHUPPending = false
    do { try hostWriter.enqueue(RelayCodec.stage("supervisor_ready", generation)) } catch { return 31 }
    func cancel(_ failed: Bool) {
        // 停止不得把已读但未交付的数据丢弃解释为正常完成。
        if failed || hostWriter.occupied || creditPending != nil || coreReader.partial || coreWriter.occupied {
            if localFailure == 0 { localFailure = 31 }
        }
        if !stopping {
            stopping = true
            authority.revoke(launch: sdkLaunch, generation: generation)
            mailbox.cancel()
            owner.controlEOF()
        }
    }
    while true {
        owner.tick()
        let snapshot = owner.snapshot()
        if snapshot.failure != nil { cancel(true) }
        if snapshot.confirmedExited {
            authority.revoke(launch: sdkLaunch, generation: generation); mailbox.cancel()
            // 未由管道停止路径发起的提前退出，不能证明stdout已完整交付。
            if !stopping { localFailure = 31 }
            return localFailure == 0 && snapshot.failure == nil ? 0 : 31
        }
        if stopping {
            if !snapshot.ownsChild { return localFailure }
            // 未知出生/回收状态必须保留owner，不能用helper退出冒充完成。
            var empty: [HRPoll] = []
            _ = empty.withUnsafeMutableBufferPointer { HRPollOnce($0.baseAddress, 0, 20) }
            continue
        }
        if phase == .preparing && backend.now >= initialDeadline { cancel(true); continue }
        if let completed = mailbox.take() {
            switch completed {
            case let .prepared(seal, proof):
                guard phase == .preparing, backend.now < initialDeadline else { cancel(true); continue }
                artifact = seal; helperProof = proof
            case let .core(identity, accepted):
                guard phase == .coreIdentity, request == identity else { cancel(true); continue }
                owner.submit(IdentityResult(request: identity, accepted: accepted))
                guard owner.snapshot().proofPermitted, let ends = owner.relayEndpoints(),
                      HRConfigure(ends.input) == 0, HRConfigure(ends.output) == 0,
                      let wireLaunch else { cancel(true); continue }
                endpoint = ends
                do { try hostWriter.enqueue(RelayCodec.stage("core_ready", generation, launch: wireLaunch, pid: ends.pid)) }
                catch { cancel(true); continue }
                hostFrame = .coreReady; phase = .hello
            case .rejected: cancel(true); continue
            }
        }
        if phase == .preparing, readySent, let artifact, let helperProof, wireLaunch != nil {
            // owner.start在spawn之前起算单一Core预算；SDK阶段不重置它。
            guard let identity = owner.start(artifact: artifact, launch: 1, generation: generation) else { cancel(true); continue }
            request = identity; phase = .coreIdentity
            guard mailbox.launch({
                do {
                    let proof = try authority.bindCoreChain(helperProof, coreLocatorPID: identity.stamp.pid)
                    try authority.recheck(proof)
                    return .core(identity, true)
                } catch { return .core(identity, false) }
            }) else { cancel(true); continue }
        }
        // credit与result共享单host writer；只允许额外一个4096以内credit。
        if !hostWriter.occupied, let credit = creditPending {
            do { try hostWriter.enqueue(credit); creditPending = nil; hostFrame = .credit }
            catch { cancel(true); continue }
        }
        let canReadHost = (phase == .preparing && wireLaunch == nil) ||
            (phase == .hello && coreReadySent) || (phase == .business && hostPermission && !coreWriter.occupied)
        let canReadCore = endpoint != nil && !hostWriter.occupied && creditPending == nil &&
            (phase == .ack || phase == .business)
        var polls = [HRPoll(fd: STDIN_FILENO, events: Int16(canReadHost ? HR_READ : 0), returned: 0),
                     HRPoll(fd: STDOUT_FILENO, events: Int16(hostWriter.occupied ? HR_WRITE : 0), returned: 0)]
        if let endpoint {
            polls.append(HRPoll(fd: endpoint.input, events: Int16(coreWriter.occupied ? HR_WRITE : 0), returned: 0))
            // 已记录HUP且因host背压暂停时暂不重复poll该FD，避免HUP忙循环。
            // 恢复读取许可后必须重新poll并实际read，不能用HUP猜测EOF。
            polls.append(HRPoll(fd: coreHUPPending && !canReadCore ? -1 : endpoint.output,
                                events: Int16(canReadCore ? HR_READ : 0), returned: 0))
        }
        let polled = polls.withUnsafeMutableBufferPointer { HRPollOnce($0.baseAddress, $0.count, 20) }
        guard polled >= 0 else { cancel(true); continue }
        // 先推进tick再使用poll返回的借用FD；owner可能已撤销/关闭端点。
        owner.tick()
        let afterPoll = owner.snapshot()
        if afterPoll.failure != nil || (endpoint != nil && !afterPoll.proofPermitted) { cancel(true); continue }
        if polls.contains(where: { $0.returned & Int16(HR_ERROR) != 0 }) { cancel(true); continue }
        if polls[0].returned & Int16(HR_HUP) != 0 {
            // HUP可能先于READ；只有管道明确为空才可按无残留输入停止。
            var pending: UInt8 = 0
            let amount = HRRead(STDIN_FILENO, &pending, 1)
            cancel(hostReader.partial || phase != .business || amount != 0)
            continue
        }
        if polls[1].returned & Int16(HR_HUP) != 0 { cancel(true); continue }
        if endpoint != nil, polls[3].returned & Int16(HR_HUP) != 0 { coreHUPPending = true }
        do {
            if polls[1].returned & Int16(HR_WRITE) != 0, try hostWriter.write(fd: STDOUT_FILENO) {
                switch hostFrame {
                case .ready: readySent = true
                case .coreReady: coreReadySent = true
                case .ack:
                    guard let request, owner.handshakeCommitted(launch: request.launch, generation: request.generation, epoch: request.epoch) else { throw RelayError.invalid }
                    phase = .business; hostPermission = true
                case .credit: hostPermission = true
                case .result: break
                }
            }
            if canReadHost, polls[0].returned & Int16(HR_READ) != 0,
               let payload = try hostReader.read(fd: STDIN_FILENO, limit: phase == .business ? RelayCodec.businessLimit : RelayCodec.stageLimit) {
                switch phase {
                case .preparing: wireLaunch = try RelayCodec.prepare(payload, generation: generation)
                case .hello:
                    try RelayCodec.helloOrAck(payload, kind: "hello", generation: generation)
                    try coreWriter.enqueue(payload); phase = .writingHello
                case .business:
                    try RelayCodec.action(payload, generation: generation)
                    hostPermission = false; try coreWriter.enqueue(payload)
                default: throw RelayError.invalid
                }
            }
            if let endpoint, polls[2].returned & Int16(HR_WRITE) != 0, try coreWriter.write(fd: endpoint.input) {
                if phase == .writingHello { phase = .ack }
                else {
                    guard phase == .business, creditPending == nil, sequence < UInt64(Int64.max) else { throw RelayError.invalid }
                    sequence += 1; creditPending = RelayCodec.credit(generation, sequence: sequence)
                }
            }
            if let endpoint, canReadCore,
               polls[3].returned & Int16(HR_READ) != 0 || coreHUPPending {
                do {
                    if let payload = try coreReader.read(fd: endpoint.output, limit: phase == .business ? RelayCodec.businessLimit : RelayCodec.stageLimit) {
                        if phase == .ack {
                            try RelayCodec.helloOrAck(payload, kind: "ack", generation: generation)
                            phase = .publishingAck; hostFrame = .ack
                        } else { try RelayCodec.result(payload, generation: generation); hostFrame = .result }
                        try hostWriter.enqueue(payload)
                    }
                } catch RelayError.eof {
                    // read==0且reader无partial才是明确EOF；Core自主终止输出为失败。
                    cancel(true)
                }
            }
        } catch { cancel(true) }
    }
}
