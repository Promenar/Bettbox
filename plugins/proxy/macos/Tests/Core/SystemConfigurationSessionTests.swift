import Foundation
import XCTest
@testable import MacosProxyTransactionCore

// 只注入原生资源调用，不执行系统认证、SC锁或配置写入。
final class SystemConfigurationSessionTests: XCTestCase {
    func testPartialAuthorizationCreationFailureFreesOnce() {
        let construction = FakeSCSessionConstruction(); construction.authorizationFailure = .authorizationCancelled
        let factory = AuthorizedSCSessionFactory(constructionFactory: { construction })
        XCTAssertThrowsError(try factory.createSession()) { error in
            XCTAssertEqual(error as? BackendFailure, .authorizationCancelled)
        }
        XCTAssertEqual(construction.events, ["createAuthorization", "freeAuthorization"])
        XCTAssertNoThrow(try construction.releaseAuthorization())
        XCTAssertEqual(construction.events.filter { $0 == "freeAuthorization" }.count, 1)
    }

    func testPreferencesCreationFailureFreesPartialAuthorization() {
        let construction = FakeSCSessionConstruction(); construction.sessionFailure = .permissionDenied
        let factory = AuthorizedSCSessionFactory(constructionFactory: { construction })
        XCTAssertThrowsError(try factory.createSession()) { error in
            XCTAssertEqual(error as? BackendFailure, .permissionDenied)
        }
        XCTAssertEqual(construction.events, ["createAuthorization", "createSession", "freeAuthorization"])
        XCTAssertEqual(construction.resource.events, [])
    }

    func testPartialCleanupFailureOverridesAuthorizationCancellationAndPoisonsBackend() {
        let construction = FakeSCSessionConstruction()
        construction.authorizationFailure = .authorizationCancelled; construction.cleanupFailure = true
        let factory = AuthorizedSCSessionFactory(constructionFactory: { construction })
        let backend = SystemConfigurationBackend(sessionFactory: factory)
        XCTAssertThrowsError(try backend.lock()) { error in
            XCTAssertEqual(error as? BackendFailure, .sessionCleanupFailed)
        }
        XCTAssertThrowsError(try backend.lock()) { error in
            XCTAssertEqual(error as? BackendFailure, .readFailed)
        }
        XCTAssertEqual(construction.events, ["createAuthorization", "freeAuthorization"])
    }

    func testSuccessfulConstructionTransfersCleanupToSessionLifecycle() throws {
        let construction = FakeSCSessionConstruction()
        let factory = AuthorizedSCSessionFactory(constructionFactory: { construction })
        let lifecycle = SCSessionLifecycle(try factory.createSession())
        try lifecycle.lock(); try lifecycle.close()
        XCTAssertEqual(construction.events, ["createAuthorization", "createSession"])
        XCTAssertEqual(construction.resource.events, ["lock", "synchronize", "unlock", "releaseSession", "freeAuthorization"])
    }

    func testBackendCloseFailureIsThrownAndPreventsReuse() throws {
        let factory = FakeSCSessionFactory(); factory.resource.unlockFailure = true
        let backend = SystemConfigurationBackend(sessionFactory: factory)
        try backend.lock()
        XCTAssertThrowsError(try backend.unlockDiscardingStagedChanges()) { error in
            XCTAssertEqual(error as? BackendFailure, .sessionCleanupFailed)
        }
        XCTAssertThrowsError(try backend.lock())
        XCTAssertEqual(factory.creates, 1)
        XCTAssertEqual(factory.resource.events.filter { $0 == "freeAuthorization" }.count, 1)
    }

    func testFactoryCreationFailureDoesNotAcquireOrReleaseResources() {
        let factory = FakeSCSessionFactory(); factory.failure = .permissionDenied
        let backend = SystemConfigurationBackend(sessionFactory: factory)
        XCTAssertThrowsError(try backend.lock()) { error in
            XCTAssertEqual(error as? BackendFailure, .permissionDenied)
        }
        XCTAssertEqual(factory.creates, 1)
        XCTAssertEqual(factory.resource.events, [])
    }

    func testUnsuccessfulLockDoesNotUnlockAndFreesExactlyOnce() {
        let factory = FakeSCSessionFactory(); factory.resource.lockFailure = .authorizationCancelled
        let backend = SystemConfigurationBackend(sessionFactory: factory)
        XCTAssertThrowsError(try backend.lock())
        XCTAssertEqual(factory.resource.events, ["lock", "releaseSession", "freeAuthorization"])
    }

    func testSessionClosesBeforeAuthorizationAndDuplicateCloseIsHarmless() throws {
        let resource = FakeSCSessionResource()
        let lifecycle = SCSessionLifecycle(resource)
        try lifecycle.lock(); try lifecycle.close(); try lifecycle.close()
        XCTAssertEqual(resource.events, ["lock", "synchronize", "unlock", "releaseSession", "freeAuthorization"])
    }

    func testNeverLockedSessionReleasesWithoutUnlock() throws {
        let resource = FakeSCSessionResource()
        let lifecycle = SCSessionLifecycle(resource)
        try lifecycle.close(); try lifecycle.close()
        XCTAssertEqual(resource.events, ["releaseSession", "freeAuthorization"])
    }

    func testUnlockFailureStillReleasesBothResourcesExactlyOnce() throws {
        let resource = FakeSCSessionResource(); resource.unlockFailure = true
        let lifecycle = SCSessionLifecycle(resource)
        try lifecycle.lock()
        XCTAssertThrowsError(try lifecycle.close())
        try lifecycle.close()
        XCTAssertEqual(resource.events, ["lock", "synchronize", "unlock", "releaseSession", "freeAuthorization"])
    }

    func testAuthorizationFreeFailureDoesNotRetryFree() throws {
        let resource = FakeSCSessionResource(); resource.freeFailure = true
        let lifecycle = SCSessionLifecycle(resource)
        try lifecycle.lock()
        XCTAssertThrowsError(try lifecycle.close())
        try lifecycle.close()
        XCTAssertEqual(resource.events.filter { $0 == "freeAuthorization" }.count, 1)
    }
}

final class SessionTestCurrentFlag {
    private let lock = NSLock()
    private var current = true
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return current }
    func revoke() { lock.lock(); current = false; lock.unlock() }
}
