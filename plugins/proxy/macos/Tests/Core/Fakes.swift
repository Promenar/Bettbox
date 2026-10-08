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
                 .wpad: .automatic(AutomaticProxy(enabled: nil, unchangedConfigurationDigest: String(repeating: "b", count: 64)))],
        unownedDigest: String(repeating: "c", count: 64))
}

func publicCapability(port: Int = 7890, bypass: [String] = ["localhost", "*.public.example"],
                      generation: UInt64 = 7, epoch: UInt64 = 1,
                      current: @escaping () -> Bool = { true }) -> CredentialBlindEndpointCapability {
    CredentialBlindEndpointCapability(supervisorGeneration: generation, listenerEpoch: epoch,
                                      host: "127.0.0.1", port: port, state: "active",
                                      bypass: bypass, current: current)!
}

final class FakeConfiguration: ConfigurationBackend {
    var services: [ServiceSnapshot]
    var active: [String: ActiveServiceSnapshot]
    var unownedFields = ["public-service": ["public-unknown-key": "preserve-public-value"]]
    var locked = false
    var lockFailure: BackendFailure?
    var stageFailureAt: Int?
    var commitFailure: BackendFailure?
    var applyFailure = false
    var applyBeforeFailure = false
    var verificationMismatch = false
    var nextRead: (() -> Void)?
    var beforeStage: (() -> Void)?
    var afterStage: (() -> Void)?
    var afterCommit: (() -> Void)?
    var arbitraryReadError: Error?
    var stages = 0
    var commits = 0
    var applies = 0
    var lockCount = 0
    var lockAttempts = 0
    private var pending: [String: [ProxyGroup: GroupValue]] = [:]

    init(_ services: [ServiceSnapshot] = [publicService()]) {
        self.services = services
        active = Dictionary(uniqueKeysWithValues: services.map {
            ($0.id, ActiveServiceSnapshot(authentication: $0.authentication, groups: $0.groups,
                                           unownedDigest: String(repeating: "d", count: 64)))
        })
    }
    func lock() throws {
        lockAttempts += 1
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
    func activeServices(serviceIDs: [String]) throws -> [String: ActiveServiceSnapshot] {
        precondition(locked)
        return active.filter { serviceIDs.contains($0.key) }
    }
    func stage(serviceID: String, replacements: [ProxyGroup: GroupValue],
               expected: [ProxyGroup: GroupValue], expectedUnownedDigest: String) throws {
        precondition(locked)
        stages += 1
        let beforeCallback = beforeStage; beforeStage = nil; beforeCallback?()
        if stages == stageFailureAt { throw BackendFailure.stageFailed }
        guard let service = services.first(where: { $0.id == serviceID }),
              Set(replacements.keys) == Set(expected.keys),
              expected.allSatisfy({ service.groups[$0.key] == $0.value }),
              service.unownedDigest == expectedUnownedDigest else {
            throw BackendFailure.stageFailed
        }
        pending[serviceID, default: [:]].merge(replacements) { _, new in new }
        let afterCallback = afterStage; afterStage = nil; afterCallback?()
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
            active = Dictionary(uniqueKeysWithValues: services.map { service in
                let previous = active[service.id]
                return (service.id, ActiveServiceSnapshot(
                    authentication: previous?.authentication ?? service.authentication,
                    groups: service.groups,
                    unownedDigest: previous?.unownedDigest ?? service.unownedDigest))
            })
            if verificationMismatch { active[services[0].id]?[.http] = publicService().groups[.http] }
        }
        if applyFailure { throw BackendFailure.applyFailed }
    }
}

final class FakeJournal: JournalBackend {
    let installOwnerID = UUID()
    var record: OwnershipJournal?
    var legacyRecord: LegacyOwnershipJournalV3?
    var acquired = false
    var loadFailure = false
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
    func load() throws -> LoadedOwnershipJournal? {
        precondition(acquired)
        if loadFailure { throw JournalFailure.unavailable }
        if let legacyRecord { return .legacyV3(legacyRecord) }
        return record.map(LoadedOwnershipJournal.current)
    }
    func persist(_ journal: OwnershipJournal) throws {
        precondition(acquired)
        if persistFailure == journal.phase { throw JournalFailure.unavailable }
        if completedProgressSaveFailure && !journal.restoration.verifiedRestored.isEmpty {
            throw JournalFailure.unavailable
        }
        legacyRecord = nil
        record = journal; persistedPhases.append(journal.phase); persistedRecords.append(journal)
    }
    func clear() throws {
        precondition(acquired)
        if clearFailure { throw JournalFailure.unavailable }
        record = nil; legacyRecord = nil
    }
}
