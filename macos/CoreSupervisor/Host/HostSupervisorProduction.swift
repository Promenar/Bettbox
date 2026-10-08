import Foundation

// 固定入口创建 host 角色，不接受 Flutter 路径、UID 或签名期待值。
extension SSISealedHelperDescriptor: SSIHostHelperDescriptor {
    // 描述符自身持有 helper 与 manifest FD；返回对象只用于延长所有权，不暴露 fd。
    var heldFD: AnyObject { self }
}
private final class SSIProductionHostFacts: SSIHostFacts {
    private let backend = SSIAppleBackend(role: .host)
    func verifiedHelperForHost() throws -> SSIHostHelperDescriptor {
        let descriptor = try backend.verifiedHelperForHost()
        try descriptor.recheck()
        return descriptor
    }
    func kernelRead(_ pid: Int32) -> SSIHostKernelRead {
        switch backend.kernelRead(pid) {
        case .present(let stamp): return .present(stamp)
        case .absent: return .absent
        case .unknown: return .unknown
        }
    }
}
func makeHostSupervisorAuthority() -> HostSupervisorAuthority {
    let transaction = ProxyTransaction(configuration: SystemConfigurationBackend(),
                                       journal: ProtectedJournalBackend())
    let coordinator = HostSystemProxyCoordinator(lifecycle: ProxyLifecycle(transaction: transaction))
    return HostSupervisorAuthority(facts: SSIProductionHostFacts(), authority: makeSSIHostAuthority(),
                                   proxy: coordinator)
}
