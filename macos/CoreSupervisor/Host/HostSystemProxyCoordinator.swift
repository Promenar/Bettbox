import Foundation

// Host 只依赖此异步边界；fake 可控制完成顺序，生产实现不在调用线程执行 SC 或 journal I/O。
protocol HostSystemProxyCoordinating: AnyObject {
    func prepare(completion: @escaping (SafeResult) -> Void)
    func recover(completion: @escaping (SafeResult) -> Void)
    func start(_ capability: CredentialBlindEndpointCapability, completion: @escaping (SafeResult) -> Void)
    func restore(completion: @escaping (SafeResult) -> Void)
}

final class HostSystemProxyCoordinator: HostSystemProxyCoordinating {
    private enum Preparation {
        case unstarted
        case pending([(SafeResult) -> Void])
        case complete(SafeResult)
    }

    private let lifecycle: ProxyLifecycle
    private let lock = NSLock()
    private var preparation: Preparation = .unstarted

    init(lifecycle: ProxyLifecycle) { self.lifecycle = lifecycle }

    func prepare(completion: @escaping (SafeResult) -> Void) {
        lock.lock()
        switch preparation {
        case .unstarted:
            preparation = .pending([completion])
            lock.unlock()
            lifecycle.recover { [weak self] result in
                guard let self else { return }
                lock.lock()
                guard case .pending(let completions) = preparation else {
                    lock.unlock(); return
                }
                preparation = .complete(result)
                lock.unlock()
                completions.forEach { $0(result) }
            }
        case .pending(var completions):
            completions.append(completion)
            preparation = .pending(completions)
            lock.unlock()
        case .complete(let result):
            lock.unlock()
            completion(result)
        }
    }

    func recover(completion: @escaping (SafeResult) -> Void) {
        lifecycle.recover(completion: completion)
    }

    func start(_ capability: CredentialBlindEndpointCapability, completion: @escaping (SafeResult) -> Void) {
        lifecycle.start(capability, completion: completion)
    }

    func restore(completion: @escaping (SafeResult) -> Void) {
        lifecycle.stop(completion: completion)
    }
}
