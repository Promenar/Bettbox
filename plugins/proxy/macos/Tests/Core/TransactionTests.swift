import Foundation
import XCTest
@testable import MacosProxyTransactionCore

final class TransactionTests: XCTestCase {
    let intent = ProxyIntent(port: 7890, bypass: ["localhost", "*.public.example"])

    func testStartStopPreservesMissingKeysAndUnownedFields() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let before = backend.services[0].groups
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        XCTAssertEqual(store.record?.phase, .verifiedApplied)
        XCTAssertEqual(transaction.stop(generation: 2).status, .restored)
        XCTAssertEqual(backend.services[0].groups, before)
        XCTAssertEqual(backend.active["public-service"], before)
        XCTAssertEqual(backend.unownedFields["public-service"]?["public-unknown-key"], "preserve-public-value")
        XCTAssertNil(store.record)
        XCTAssertFalse(backend.locked)
    }

    func testEnabledOrUnknownActiveSOCKSRefusesAllWrites() {
        for activeOnly in [false, true] {
            let backend = FakeConfiguration(), store = FakeJournal()
            if activeOnly { backend.active["public-service"]?[.socks] = .manual(ManualProxy(enabled: true, host: "external.example", port: 1080)) }
            else { backend.services[0].groups[.socks] = .manual(ManualProxy(enabled: true, host: "external.example", port: 1080)) }
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .unsupportedSOCKSProxy)
            XCTAssertEqual(backend.stages, 0); XCTAssertNil(store.record)
        }
        let backend = FakeConfiguration(), store = FakeJournal()
        backend.active = [:]
        XCTAssertEqual(ProxyTransaction(configuration: backend, journal: store).start(intent, generation: 1, isCurrent: { true }).status, .recoveryRequired)
        XCTAssertEqual(backend.stages, 0)
    }
    func testPriorSOCKSJournalSchemaRefusesAutomaticRecovery() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        let original = store.record!
        store.record = OwnershipJournal(schemaVersion: 2, installOwnerID: original.installOwnerID,
            generation: original.generation, transactionID: original.transactionID,
            intent: original.intent, phase: original.phase, entries: original.entries)
        let before = backend.stages
        XCTAssertEqual(transaction.stop(generation: 2).status, .recoveryRequired)
        XCTAssertEqual(backend.stages, before)
    }
    func testInactiveServicesAreNotClaimed() {
        var inactive = publicService("inactive-service"); inactive.active = false
        let backend = FakeConfiguration([publicService(), inactive]), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        XCTAssertEqual(store.record?.entries.map { $0.serviceID }, ["public-service"])
        XCTAssertEqual(backend.services[1].groups, inactive.groups)
    }
    func testHTTPOnlyStartDoesNotOwnOrChangeSOCKS() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let original = backend.services[0].groups[.socks]
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        XCTAssertEqual(backend.services[0].groups[.socks], original)
        XCTAssertFalse(store.record!.entries[0].ownedGroups.contains(.socks))
    }

    func testInitialStopDoesNotTouchAnyConfiguration() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.stop(generation: 1).status, .idle)
        XCTAssertEqual(backend.stages, 0); XCTAssertEqual(backend.commits, 0); XCTAssertEqual(backend.applies, 0)
    }

    func testAuthenticationPresentAndUnknownRejectAllServicesBeforeSetter() {
        for authentication in [AuthenticationState.present, .unknown] {
            var unsafe = publicService("second-service")
            unsafe.authentication = authentication
            let backend = FakeConfiguration([publicService(), unsafe]), store = FakeJournal()
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .unsupportedAuthenticatedProxy)
            XCTAssertEqual(backend.stages, 0); XCTAssertNil(store.record)
        }
    }

    func testInvalidInputAndUserinfoNeverPersistOrWrite() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(ProxyIntent(port: 0, bypass: []), generation: 1, isCurrent: { true }).status, .invalidInput)
        backend.services[0].groups[.http] = .manual(ManualProxy(enabled: false, host: "public-user:fictional-pass@proxy.example", port: 80))
        XCTAssertEqual(transaction.start(intent, generation: 2, isCurrent: { true }).status, .recoveryRequired)
        XCTAssertEqual(backend.stages, 0); XCTAssertNil(store.record)
    }

    func testPartialStageFailureAndProvenRejectedCommitDoNotChangePersistentValues() {
        for rejectCommit in [false, true] {
            let backend = FakeConfiguration([publicService(), publicService("second-service")]), store = FakeJournal()
            let before = backend.services.map { $0.groups }
            if rejectCommit { backend.commitFailure = .commitRejected } else { backend.stageFailureAt = 2 }
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .failedRolledBack)
            XCTAssertEqual(backend.services.map { $0.groups }, before)
            XCTAssertEqual(backend.applies, 0)
            XCTAssertNil(store.record)
            XCTAssertFalse(backend.locked)
            if !rejectCommit { XCTAssertEqual(backend.commits, 0) }
        }
    }

    func testCommitUnknownApplyUnknownAndVerificationFailureNeverBecomeRecoverable() {
        for mode in 0...3 {
            let backend = FakeConfiguration(), store = FakeJournal()
            if mode == 0 { backend.commitFailure = .commitUncertain }
            if mode == 1 { backend.applyFailure = true }
            if mode == 2 { backend.applyFailure = true; backend.applyBeforeFailure = true }
            if mode == 3 { backend.verificationMismatch = true }
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .recoveryRequired)
            XCTAssertEqual(store.record?.phase, .uncertain)
            let stages = backend.stages, commits = backend.commits
            XCTAssertEqual(transaction.recover(generation: 2).status, .recoveryRequired)
            XCTAssertEqual(backend.stages, stages); XCTAssertEqual(backend.commits, commits)
        }
    }

    func testJournalFailureBeforeWriteAndAfterApplyRemainFailClosed() {
        for phase in [JournalPhase.prepared, .committed, .verifiedApplied] {
            let backend = FakeConfiguration(), store = FakeJournal(); store.persistFailure = phase
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .recoveryRequired)
            if phase == .prepared { XCTAssertEqual(backend.stages, 0); XCTAssertEqual(backend.commits, 0) }
            else {
                XCTAssertNotEqual(store.record?.phase, .verifiedApplied)
                let commits = backend.commits
                XCTAssertEqual(transaction.recover(generation: 2).status, .recoveryRequired)
                XCTAssertEqual(backend.commits, commits)
            }
        }
    }

    func testPreparedAndCommittedCrashRecordsNeverRestoreEvenWhenValuesMatch() {
        for phase in [JournalPhase.prepared, .committed, .uncertain] {
            let backend = FakeConfiguration(), store = FakeJournal()
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
            store.record?.phase = phase
            let commits = backend.commits
            XCTAssertEqual(transaction.recover(generation: 2).status, .recoveryRequired)
            XCTAssertEqual(backend.commits, commits)
        }
    }

    func testExternalProxyAndPACGuardChangesArePreservedWhileOtherGroupsRestore() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        let originalEntries = store.record!.entries
        let external = GroupValue.manual(ManualProxy(enabled: true, host: "external.example", port: 8443))
        let pac = GroupValue.automatic(AutomaticProxy(enabled: false, unchangedConfigurationDigest: String(repeating: "c", count: 64)))
        backend.services[0].groups[.http] = external; backend.active["public-service"]?[.http] = external
        backend.services[0].groups[.pac] = pac; backend.active["public-service"]?[.pac] = pac
        let result = transaction.stop(generation: 2)
        XCTAssertEqual(result.status, .conflict); XCTAssertEqual(result.unresolvedGroups, 2)
        XCTAssertEqual(backend.services[0].groups[.http], external)
        XCTAssertEqual(backend.active["public-service"]?[.pac], pac)
        XCTAssertEqual(backend.services[0].groups[.socks], publicService().groups[.socks])
        XCTAssertEqual(store.record?.phase, .uncertain)
        let restored = Set([ProxyGroup.https, .bypass, .wpad].map {
            OwnedGroupID(serviceID: "public-service", group: $0)
        })
        let conflicts = Set([ProxyGroup.http, .pac].map {
            OwnedGroupID(serviceID: "public-service", group: $0)
        })
        XCTAssertEqual(store.record?.restoration.verifiedRestored, restored)
        XCTAssertEqual(store.record?.restoration.remainingConflicts, conflicts)
        XCTAssertEqual(store.record?.entries, originalEntries)
        let commits = backend.commits
        XCTAssertEqual(transaction.recover(generation: 3).status, .recoveryRequired)
        XCTAssertEqual(backend.commits, commits)
    }

    func testRunningMismatchAndDeletedServiceCannotBeOverwritten() {
        for deleteService in [false, true] {
            let backend = FakeConfiguration(), store = FakeJournal()
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
            if deleteService { backend.services = [] }
            else { backend.active["public-service"] = publicService().groups }
            let commits = backend.commits
            XCTAssertEqual(transaction.recover(generation: 2).status, .conflict)
            XCTAssertEqual(backend.commits, commits)
        }
    }

    func testRepeatedStartAndPortChangeKeepOriginalOwnershipSnapshot() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let before = backend.services[0].groups
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        let commits = backend.commits
        XCTAssertEqual(transaction.start(intent, generation: 2, isCurrent: { true }).status, .applied)
        XCTAssertEqual(backend.commits, commits)
        XCTAssertEqual(transaction.start(ProxyIntent(port: 7891, bypass: []), generation: 3, isCurrent: { true }).status, .applied)
        XCTAssertEqual(store.record?.entries[0].before, before)
        XCTAssertEqual(transaction.stop(generation: 4).status, .restored)
        XCTAssertEqual(backend.services[0].groups, before)
    }

    func testSecondOwnerAndPermissionDeniedAreFixedSafeFailures() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let owner = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(owner.stop(generation: 1).status, .idle)
        let other = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(other.stop(generation: 2).status, .busy)
        backend.lockFailure = .permissionDenied
        XCTAssertEqual(owner.start(intent, generation: 3, isCurrent: { true }).status, .permissionDenied)
        XCTAssertEqual(backend.stages, 0)
    }

    func testRawDiagnosticsDoNotCrossSafeResult() {
        let backend = FakeConfiguration(), store = FakeJournal()
        backend.arbitraryReadError = NSError(domain: "PUBLIC_FAKE_SECRET_DIAGNOSTIC", code: 123,
            userInfo: [NSLocalizedDescriptionKey: "https://public-user:fictional-password@example.test/private-pac"])
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        let result = transaction.start(intent, generation: 1, isCurrent: { true })
        XCTAssertEqual(result.status, .recoveryRequired)
        let text = String(reflecting: result)
        XCTAssertFalse(text.contains("FAKE_SECRET")); XCTAssertFalse(text.contains("fictional-password"))
    }

    func testRestoreRejectedCommitLeavesVerifiedEvidenceForSafeRetry() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        let written = backend.services[0].groups
        backend.commitFailure = .commitRejected
        XCTAssertEqual(transaction.stop(generation: 2).status, .failedRolledBack)
        XCTAssertEqual(backend.services[0].groups, written)
        XCTAssertEqual(store.record?.phase, .verifiedApplied)
        backend.commitFailure = nil
        XCTAssertEqual(transaction.stop(generation: 3).status, .restored)
        XCTAssertEqual(backend.services[0].groups, publicService().groups)
    }

    func testForeignJournalAndCleanupFailureCannotClaimSuccessfulRecovery() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        let original = store.record!
        store.record = OwnershipJournal(schemaVersion: original.schemaVersion, installOwnerID: UUID(),
            generation: original.generation, transactionID: original.transactionID,
            intent: original.intent, phase: .verifiedApplied, entries: original.entries)
        let commits = backend.commits
        XCTAssertEqual(transaction.recover(generation: 2).status, .recoveryRequired)
        XCTAssertEqual(backend.commits, commits)
        store.record = original; store.clearFailure = true
        XCTAssertEqual(transaction.stop(generation: 3).status, .recoveryRequired)
        XCTAssertEqual(store.record?.phase, .uncertain)
        XCTAssertNotNil(store.record)
    }

    func testCompletedProgressSaveFailureDoesNotInventDurableRestoration() {
        let backend = FakeConfiguration(), store = FakeJournal()
        let transaction = ProxyTransaction(configuration: backend, journal: store)
        XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
        let originalEntries = store.record!.entries
        let external = GroupValue.manual(ManualProxy(enabled: true, host: "external.example", port: 8443))
        backend.services[0].groups[.http] = external; backend.active["public-service"]?[.http] = external
        store.completedProgressSaveFailure = true
        XCTAssertEqual(transaction.stop(generation: 2).status, .recoveryRequired)
        XCTAssertEqual(store.record?.phase, .uncertain)
        XCTAssertEqual(store.record?.restoration.verifiedRestored, [])
        XCTAssertEqual(store.record?.restoration.remainingConflicts,
                       [OwnedGroupID(serviceID: "public-service", group: .http)])
        XCTAssertEqual(store.record?.entries, originalEntries)
        XCTAssertFalse(store.persistedRecords.contains { !$0.restoration.verifiedRestored.isEmpty })
        XCTAssertEqual(backend.services[0].groups[.http], external)
    }

    func testTamperedProgressCannotBypassJournalSchemaOrBecomeRecoverable() {
        for mode in 0...3 {
            let backend = FakeConfiguration(), store = FakeJournal()
            let transaction = ProxyTransaction(configuration: backend, journal: store)
            XCTAssertEqual(transaction.start(intent, generation: 1, isCurrent: { true }).status, .applied)
            let owned = OwnedGroupID(serviceID: "public-service", group: .http)
            if mode == 0 {
                let original = store.record!
                store.record = OwnershipJournal(schemaVersion: 1, installOwnerID: original.installOwnerID,
                    generation: original.generation, transactionID: original.transactionID,
                    intent: original.intent, phase: original.phase, entries: original.entries)
            }
            if mode == 1 { store.record?.restoration.verifiedRestored = [owned] }
            if mode == 2 {
                store.record?.phase = .uncertain
                store.record?.restoration.verifiedRestored = [OwnedGroupID(serviceID: "unknown-service", group: .http)]
            }
            if mode == 3 {
                store.record?.phase = .uncertain
                store.record?.restoration.verifiedRestored = [owned]
                store.record?.restoration.remainingConflicts = [owned]
            }
            let commits = backend.commits
            XCTAssertEqual(transaction.recover(generation: 2).status, .recoveryRequired)
            XCTAssertEqual(backend.commits, commits)
        }
    }
}
