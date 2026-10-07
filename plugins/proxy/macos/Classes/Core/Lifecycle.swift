import Foundation

// 代次分配与提交队列共享临界区；所有实际操作在私有串行 worker 上执行。
enum LifecycleRequest: Equatable { case start, stop, recover }
final class ProxyLifecycle {
    private let transaction: ProxyTransaction
    private let worker: DispatchQueue
    private let intentLock = NSLock()
    private var epoch: UInt64 = 0
    private var exhausted = false
    // 仅用于确定性交错 fixture；在锁内调用，不可重入生命周期方法。
    private let beforeSubmissionForTesting: ((LifecycleRequest, UInt64) -> Void)?

    init(transaction: ProxyTransaction, worker: DispatchQueue = DispatchQueue(label: "bettbox.proxy.draft"),
         beforeSubmissionForTesting: ((LifecycleRequest, UInt64) -> Void)? = nil) {
        self.transaction = transaction
        self.worker = DispatchQueue(label: "bettbox.proxy.draft.lifecycle", target: worker)
        self.beforeSubmissionForTesting = beforeSubmissionForTesting
    }

    // 调用者必须持有 intentLock，不能在取得 token 后释放再排队。
    private func advanceLocked() -> UInt64? {
        guard !exhausted && epoch < UInt64.max else { exhausted = true; return nil }
        epoch += 1
        return epoch
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        intentLock.lock()
        defer { intentLock.unlock() }
        return !exhausted && epoch == token
    }

    func start(_ intent: ProxyIntent, completion: @escaping (SafeResult) -> Void) {
        intentLock.lock()
        guard let token = advanceLocked() else {
            intentLock.unlock()
            completion(SafeResult(status: .recoveryRequired, generation: UInt64.max)); return
        }
        beforeSubmissionForTesting?(.start, token)
        worker.async { [self] in
            intentLock.lock(); intentLock.unlock()
            let result = transaction.start(intent, generation: token, isCurrent: { self.isCurrent(token) })
            if result.status == .applied && !isCurrent(token) {
                completion(SafeResult(status: .cancelled, generation: token)); return
            }
            completion(result)
        }
        intentLock.unlock()
    }

    func stop(completion: @escaping (SafeResult) -> Void) {
        intentLock.lock()
        guard let token = advanceLocked() else {
            intentLock.unlock()
            completion(SafeResult(status: .recoveryRequired, generation: UInt64.max)); return
        }
        beforeSubmissionForTesting?(.stop, token)
        worker.async { [self] in
            // 确保提交者已释放锁，再进入事务或调用 completion。
            intentLock.lock(); intentLock.unlock()
            completion(transaction.stop(generation: token))
        }
        intentLock.unlock()
    }

    func recover(completion: @escaping (SafeResult) -> Void) {
        intentLock.lock()
        let token = epoch
        beforeSubmissionForTesting?(.recover, token)
        worker.async { [self] in
            intentLock.lock(); intentLock.unlock()
            completion(transaction.recover(generation: token))
        }
        intentLock.unlock()
    }
}
