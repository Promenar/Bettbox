import Foundation
import Dispatch

enum SDKCompletion {
    case prepared(SealedCoreArtifact, SSISupervisorProof)
    case core(IdentityRequest, Bool)
    case rejected
}
// 单slot结果与单在途worker。撤销不等待Security；SDK调用不持有mailbox锁。
final class SDKMailbox {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.appshub.bettbox.supervisor.sdk")
    private var busy = false
    private var stopped = false
    private var result: SDKCompletion?
    func launch(_ body: @escaping () -> SDKCompletion) -> Bool {
        lock.lock()
        guard !busy, !stopped, result == nil else { lock.unlock(); return false }
        busy = true; lock.unlock()
        queue.async {
            let completed = body()
            self.lock.lock()
            self.busy = false
            if !self.stopped { self.result = completed }
            self.lock.unlock()
        }
        return true
    }
    func take() -> SDKCompletion? {
        lock.lock(); defer { lock.unlock() }
        let value = result; result = nil; return value
    }
    func cancel() { lock.lock(); stopped = true; result = nil; lock.unlock() }
}
