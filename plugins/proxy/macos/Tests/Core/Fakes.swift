import Foundation
@testable import MacosProxyTransactionCore

// 这些 fixture 明确声明认证为 absent；不证明真实 SC 能观测认证。
func publicService(_ id: String = "public-service") -> ServiceSnapshot {
    ServiceSnapshot(id: id, enabled: true, hasProxyProtocol: true, authentication: .absent,
        groups: [.http: .manual(ManualProxy(enabled: false, host: "proxy.example", port: 8080)),
                 .https: .manual(ManualProxy(enabled: nil, host: nil, port: nil)),
                 .socks: .manual(ManualProxy(enabled: false, host: "socks.example", port: 1080)),
                 .bypass: .bypass(["*.example", "localhost"]),
                 .pac: .automatic(AutomaticProxy(enabled: true, unchangedConfigurationDigest: String(repeating: "a", count: 64))),
                 .wpad: .automatic(AutomaticProxy(enabled: nil, unchangedConfigurationDigest: String(repeating: "b", count: 64)))])
}

final class FakeConfiguration: ConfigurationBackend {
    var services: [ServiceSnapshot]
    var active: [String: [ProxyGroup: GroupValue]]
    var unownedFields = ["public-service": ["public-unknown-key": "preserve-public-value"]]
    var locked = false
    var lockFailure: BackendFailure?
    var stageFailureAt: Int?
    var commitFailure: BackendFailure?
    var applyFailure = false
    var applyBeforeFailure = false
    var verificationMismatch = false
    var nextRead: (() -> Void)?
    var afterCommit: (() -> Void)?
    var arbitraryReadError: Error?
    var stages = 0
    var commits = 0
    var applies = 0
    var lockCount = 0
    private var pending: [String: [ProxyGroup: GroupValue]] = [:]

    init(_ services: [ServiceSnapshot] = [publicService()]) {
        self.services = services
        active = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0.groups) })
    }
    func lock() throws {
        if let failure = lockFailure { throw failure }
        guard !locked else { throw BackendFailure.busy }
        locked = true; lockCount += 1
    }
    func unlockDiscardingStagedChanges() {
        precondition(locked)
        pending = [:]; locked = false
    }
    func persistentServices() throws -> [ServiceSnapshot] {
        precondition(locked)
        let callback = nextRead; nextRead = nil; callback?()
        if let error = arbitraryReadError { throw error }
        return services
    }
    func activeGroups(serviceIDs: [String]) throws -> [String: [ProxyGroup: GroupValue]] {
        precondition(locked)
        return active.filter { serviceIDs.contains($0.key) }
    }
    func stage(serviceID: String, replacements: [ProxyGroup: GroupValue]) throws {
        precondition(locked)
        stages += 1
        if stages == stageFailureAt { throw BackendFailure.stageFailed }
        pending[serviceID, default: [:]].merge(replacements) { _, new in new }
    }
    func commit() throws {
        precondition(locked)
        commits += 1
        if commitFailure == .commitRejected { throw BackendFailure.commitRejected }
        for index in services.indices {
            if let replacements = pending[services[index].id] {
                services[index].groups.merge(replacements) { _, new in new }
            }
        }
        pending = [:]
        let callback = afterCommit; afterCommit = nil; callback?()
        if let failure = commitFailure { throw failure }
    }
    func apply() throws {
        precondition(locked)
        applies += 1
        if !applyFailure || applyBeforeFailure {
            active = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0.groups) })
            if verificationMismatch { active[services[0].id]?[.http] = publicService().groups[.http] }
        }
        if applyFailure { throw BackendFailure.applyFailed }
    }
}

final class FakeJournal: JournalBackend {
    let installOwnerID = UUID()
    var record: OwnershipJournal?
    var acquired = false
    var persistFailure: JournalPhase?
    var clearFailure = false
    var completedProgressSaveFailure = false
    var persistedPhases: [JournalPhase] = []
    var persistedRecords: [OwnershipJournal] = []
    func acquireOwnership() throws {
        guard !acquired else { throw JournalFailure.busy }
        acquired = true
    }
    func releaseOwnership() { acquired = false }
    func load() throws -> OwnershipJournal? { precondition(acquired); return record }
    func persist(_ journal: OwnershipJournal) throws {
        precondition(acquired)
        if persistFailure == journal.phase { throw JournalFailure.unavailable }
        if completedProgressSaveFailure && !journal.restoration.verifiedRestored.isEmpty {
            throw JournalFailure.unavailable
        }
        record = journal; persistedPhases.append(journal.phase); persistedRecords.append(journal)
    }
    func clear() throws {
        precondition(acquired)
        if clearFailure { throw JournalFailure.unavailable }
        record = nil
    }
}
