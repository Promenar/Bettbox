import Darwin
// 固定公开fixture入口。不是生产helper，accepted是公开stub判决，不提供SDK proof。
@main struct PublicProcessFixture {
    static func main() {
        for kind in [Int32(0), Int32(1)] {
            let backend = SystemBackend(publicFixture: kind)
            let owner = SupervisorLifecycle(backend: backend)
            if let request = owner.start(artifact: .publicFixture(), launch: UInt64(kind + 1), generation: 1) {
                owner.submit(IdentityResult(request: request, accepted: true))
                if kind == 1 {
                    precondition(owner.handshakeCommitted(launch: UInt64(kind + 1), generation: 1, epoch: 1))
                }
            }
            if kind == 1 { owner.controlEOF() }
            let end = backend.now + 9_000_000_000
            while !owner.snapshot().confirmedExited && backend.now < end { owner.tick(); usleep(10_000) }
            let state = owner.snapshot()
            precondition(state.confirmedExited && !state.ownsChild && !state.proofPermitted)
            // true可能在首次kernel读前已退出：保留kernel主错，仍须真实reap；禁止伪造正常。
            if kind == 0 { precondition(state.failure == nil || state.failure == .kernel || state.failure == .identity) }
            if kind == 1 { precondition(state.failure == .abnormalExit) }
        }
    }
}
