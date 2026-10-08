import Foundation
import XCTest
@testable import MacosProxyTransactionCore

final class LifecycleTests: XCTestCase {
    let intent = ProxyIntent(port: 7890, bypass: ["localhost"])

    func testQueuedStartCannotReplaceStopIntent() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        let worker = DispatchQueue(label: "public-fixture.queued")
        let gate = DispatchSemaphore(value: 0)
        worker.async { _ = gate.wait(timeout: .now() + 2) }
        let lifecycle = ProxyLifecycle(transaction: transaction, worker: worker)
        let start = expectation(description: "排队启动取消"), stop = expectation(description: "停止空所有权")
        lifecycle.start(publicCapability()) { result in XCTAssertEqual(result.status, .cancelled); start.fulfill() }
        lifecycle.stop { result in XCTAssertEqual(result.status, .idle); stop.fulfill() }
        gate.signal()
        wait(for: [start, stop], timeout: 2)
        XCTAssertEqual(backend.stages, 0)
        XCTAssertNil(store.record)
    }

    func testStopDuringResourceCollectionPreventsAllPublication() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let lifecycle = ProxyLifecycle(transaction: ProxyTransaction(configuration: backend, journal: store))
        let start = expectation(description: "资源收集取消"), stop = expectation(description: "停止完成")
        backend.nextRead = {
            lifecycle.stop { result in XCTAssertEqual(result.status, .idle); stop.fulfill() }
        }
        lifecycle.start(publicCapability()) { result in XCTAssertEqual(result.status, .cancelled); start.fulfill() }
        wait(for: [start, stop], timeout: 2)
        XCTAssertEqual(backend.stages, 0); XCTAssertEqual(backend.commits, 0)
    }

    func testStopAfterCommitFinishesVerificationAndCompensatesBeforeNextOperation() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let before = backend.services[0].groups
        let lifecycle = ProxyLifecycle(transaction: ProxyTransaction(configuration: backend, journal: store))
        let start = expectation(description: "提交后取消并恢复"), stop = expectation(description: "停止幂等")
        backend.afterCommit = {
            lifecycle.stop { result in XCTAssertEqual(result.status, .idle); stop.fulfill() }
        }
        lifecycle.start(publicCapability()) { result in XCTAssertEqual(result.status, .cancelled); start.fulfill() }
        wait(for: [start, stop], timeout: 2)
        XCTAssertEqual(backend.services[0].groups, before)
        XCTAssertEqual(backend.active["public-service"]?.groups, before)
        XCTAssertEqual(backend.commits, 2)
        XCTAssertNil(store.record)
        XCTAssertTrue(store.persistedPhases.contains(.verifiedApplied))
    }

    func testOnlyLatestStartPublishesAfterRapidStartStopStart() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let worker = DispatchQueue(label: "public-fixture.latest")
        let gate = DispatchSemaphore(value: 0)
        worker.async { _ = gate.wait(timeout: .now() + 2) }
        let lifecycle = ProxyLifecycle(transaction: ProxyTransaction(configuration: backend, journal: store), worker: worker)
        let first = expectation(description: "旧启动取消"), stop = expectation(description: "停止"), last = expectation(description: "新启动生效")
        lifecycle.start(publicCapability()) { result in XCTAssertEqual(result.status, .cancelled); first.fulfill() }
        lifecycle.stop { result in XCTAssertEqual(result.status, .idle); stop.fulfill() }
        lifecycle.start(publicCapability(port: 7891, bypass: [], epoch: 2)) { result in
            XCTAssertEqual(result.status, .applied); XCTAssertEqual(result.generation, 3); last.fulfill()
        }
        gate.signal()
        wait(for: [first, stop, last], timeout: 2)
        XCTAssertEqual(backend.commits, 1)
        XCTAssertEqual(store.record?.intent.port, 7891)
    }

    func testOlderStopAndRecoverSubmitBeforeNewStartWithoutQueueInversion() {
        for oldRequest in [LifecycleRequest.stop, .recover] {
            let backend = FakeConfiguration(), store = FakeJournal()
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(publicCapability(), generation: 100, isCurrent: { true }).status, .applied)
            let allocated = DispatchSemaphore(value: 0), releaseOld = DispatchSemaphore(value: 0)
            let newAttempted = DispatchSemaphore(value: 0), newReturned = DispatchSemaphore(value: 0)
            let oldDone = expectation(description: "旧请求先恢复"), newDone = expectation(description: "新启动保持生效")
            let submissionLock = NSLock()
            var submitted: [LifecycleRequest] = []
            let lifecycle = ProxyLifecycle(transaction: transaction, beforeSubmissionForTesting: { request, _ in
                submissionLock.lock(); submitted.append(request); submissionLock.unlock()
                if request == oldRequest {
                    allocated.signal()
                    XCTAssertEqual(releaseOld.wait(timeout: .now() + 2), .success)
                }
            })
            DispatchQueue.global().async {
                let completion: (SafeResult) -> Void = { result in
                    XCTAssertEqual(result.status, .restored); oldDone.fulfill()
                }
                if oldRequest == .stop { lifecycle.stop(completion: completion) }
                else { lifecycle.recover(completion: completion) }
            }
            XCTAssertEqual(allocated.wait(timeout: .now() + 2), .success)
            DispatchQueue.global().async {
                newAttempted.signal()
                lifecycle.start(publicCapability(port: 7891, bypass: [], epoch: 2)) { result in
                    XCTAssertEqual(result.status, .applied); newDone.fulfill()
                }
                newReturned.signal()
            }
            XCTAssertEqual(newAttempted.wait(timeout: .now() + 2), .success)
            // 屏障明确停在旧 token 已取得但未提交的位置；新请求不能越过该临界区。
            XCTAssertEqual(newReturned.wait(timeout: .now() + 0.05), .timedOut)
            releaseOld.signal()
            wait(for: [oldDone, newDone], timeout: 2)
            submissionLock.lock(); let order = submitted; submissionLock.unlock()
            XCTAssertEqual(order, [oldRequest, .start])
            XCTAssertEqual(store.record?.phase, .verifiedApplied)
            XCTAssertEqual(store.record?.intent.port, 7891)
            XCTAssertEqual(backend.services[0].groups[.http],
                           .manual(ManualProxy(enabled: true, host: "127.0.0.1", port: 7891)))
        }
    }

    func testCompletionCanReenterLifecycleWithoutHoldingIntentLock() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let lifecycle = ProxyLifecycle(transaction: ProxyTransaction(configuration: backend, journal: store))
        let done = expectation(description: "回调可重入停止")
        lifecycle.start(publicCapability()) { result in
            XCTAssertEqual(result.status, .applied)
            lifecycle.stop { result in XCTAssertEqual(result.status, .restored); done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        XCTAssertNil(store.record)
    }
}
