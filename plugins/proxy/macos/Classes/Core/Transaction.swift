import Foundation

private struct FixedFailure: Error { let status: SafeStatus }

final class ProxyTransaction {
    private let configuration: ConfigurationBackend
    private let journal: JournalBackend
    private let serial = NSLock()
    private var ownsJournal = false

    init(configuration: ConfigurationBackend, journal: JournalBackend) {
        self.configuration = configuration
        self.journal = journal
    }

    deinit { if ownsJournal { journal.releaseOwnership() } }

    func recover(generation: UInt64) -> SafeResult {
        operation(generation) { try self.recoverLoaded(generation) }
    }

    func stop(generation: UInt64) -> SafeResult { recover(generation: generation) }

    func start(_ capability: CredentialBlindEndpointCapability, generation: UInt64,
               isCurrent: @escaping () -> Bool) -> SafeResult {
        operation(generation) {
            let intent = capability.intent
            let current = { isCurrent() && capability.isCurrent() }
            guard intent.validate(), capability.endpoint.port == intent.port else {
                throw FixedFailure(status: .invalidInput)
            }
            guard current() else { return SafeResult(status: .cancelled, generation: generation) }
            if let old = try self.journal.load() {
                switch old {
                case .current(let record):
                    try self.validateJournal(record)
                    if record.phase == .verifiedApplied, record.intent == intent,
                       record.endpoint == capability.endpoint, try self.matchesWritten(record), current() {
                        return SafeResult(status: .applied, generation: generation)
                    }
                case .legacyV3(let record):
                    try self.validateLegacyJournal(record)
                    return SafeResult(status: .recoveryRequired, generation: generation)
                }
                let recovery = try self.recoverLoaded(generation)
                guard recovery.status == .restored || recovery.status == .idle else { return recovery }
            }
            let services = try self.configuration.persistentServices().filter { $0.enabled && $0.active }
            guard !services.isEmpty else { throw FixedFailure(status: .noServices) }
            guard services.count <= 256, Set(services.map { $0.id }).count == services.count else {
                throw FixedFailure(status: .recoveryRequired)
            }
            let running = try self.configuration.activeServices(serviceIDs: services.map { $0.id })
            var entries: [JournalEntry] = []
            // 全部服务、双读与能力预检完成后才能写journal或系统配置。
            for service in services {
                guard let active = running[service.id], !service.id.isEmpty,
                      service.hasProxyProtocol, service.authentication != .present,
                      active.authentication != .present,
                      self.validGroups(service.groups), self.validGroups(active.groups),
                      self.validDigest(service.unownedDigest), self.validDigest(active.unownedDigest) else {
                    throw FixedFailure(status: service.authentication == .present || running[service.id]?.authentication == .present
                                       ? .unsupportedAuthenticatedProxy : .recoveryRequired)
                }
                guard case .manual(let storedSOCKS)? = service.groups[.socks],
                      case .manual(let activeSOCKS)? = active.groups[.socks] else {
                    throw FixedFailure(status: .recoveryRequired)
                }
                guard storedSOCKS.enabled != true, activeSOCKS.enabled != true else {
                    throw FixedFailure(status: .unsupportedSOCKSProxy)
                }
                guard service.groups == active.groups else {
                    throw FixedFailure(status: .recoveryRequired)
                }
                let written = self.desiredGroups(intent, before: service.groups)
                let owned = Set(ProxyGroup.allCases.filter { service.groups[$0] != written[$0] })
                entries.append(JournalEntry(serviceID: service.id, before: service.groups,
                                            written: written, ownedGroups: owned,
                                            persistentUnownedDigest: service.unownedDigest,
                                            activeUnownedDigest: active.unownedDigest))
            }
            guard current() else { return SafeResult(status: .cancelled, generation: generation) }
            var record = OwnershipJournal(schemaVersion: 4,
                installOwnerID: self.journal.installOwnerID,
                transactionGeneration: generation, transactionID: UUID(),
                endpoint: capability.endpoint, intent: intent, phase: .prepared, entries: entries)
            try self.validateJournal(record)
            try self.journal.persist(record)
            do {
                for entry in entries {
                    guard current() else {
                        try self.journal.clear()
                        return SafeResult(status: .cancelled, generation: generation)
                    }
                    if !entry.ownedGroups.isEmpty {
                        try self.configuration.stage(serviceID: entry.serviceID,
                            replacements: entry.written.filter { entry.ownedGroups.contains($0.key) },
                            expected: entry.before.filter { entry.ownedGroups.contains($0.key) },
                            expectedUnownedDigest: entry.persistentUnownedDigest)
                    }
                }
                guard current() else {
                    try self.journal.clear()
                    return SafeResult(status: .cancelled, generation: generation)
                }
                guard try self.activeBaselineStillMatches(record) else {
                    try self.journal.clear()
                    return SafeResult(status: .failedRolledBack, generation: generation)
                }
            } catch {
                try self.journal.clear()
                return SafeResult(status: .failedRolledBack, generation: generation)
            }
            do {
                try self.configuration.commit()
            } catch BackendFailure.commitRejected {
                try self.journal.clear()
                return SafeResult(status: .failedRolledBack, generation: generation)
            } catch {
                record.phase = .uncertain
                try? self.journal.persist(record)
                return SafeResult(status: .recoveryRequired, generation: generation)
            }
            record.phase = .committed
            do {
                try self.journal.persist(record)
                try self.configuration.apply()
                guard try self.matchesWritten(record) else { throw BackendFailure.verificationFailed }
                record.phase = .verifiedApplied
                try self.journal.persist(record)
            } catch {
                record.phase = .uncertain
                try? self.journal.persist(record)
                return SafeResult(status: .recoveryRequired, generation: generation)
            }
            if !current() {
                let compensation = try self.recoverCurrent(record, generation: generation)
                if compensation.status == .restored {
                    return SafeResult(status: .cancelled, generation: generation,
                                      changedGroups: compensation.changedGroups)
                }
                return compensation
            }
            return SafeResult(status: .applied, generation: generation,
                              changedGroups: entries.reduce(0) { $0 + $1.ownedGroups.count })
        }
    }

    private func operation(_ generation: UInt64, body: () throws -> SafeResult) -> SafeResult {
        serial.lock()
        defer { serial.unlock() }
        do {
            if !ownsJournal { try journal.acquireOwnership(); ownsJournal = true }
            try configuration.lock()
            defer { configuration.unlockDiscardingStagedChanges() }
            return try body()
        } catch let failure as FixedFailure {
            return SafeResult(status: failure.status, generation: generation)
        } catch BackendFailure.permissionDenied {
            return SafeResult(status: .permissionDenied, generation: generation)
        } catch BackendFailure.busy {
            return SafeResult(status: .busy, generation: generation)
        } catch JournalFailure.busy {
            return SafeResult(status: .busy, generation: generation)
        } catch {
            return SafeResult(status: .recoveryRequired, generation: generation)
        }
    }

    private func recoverLoaded(_ generation: UInt64) throws -> SafeResult {
        guard let loaded = try journal.load() else {
            return SafeResult(status: .idle, generation: generation)
        }
        switch loaded {
        case .current(let record):
            try validateJournal(record)
            return try recoverCurrent(record, generation: generation)
        case .legacyV3(let record):
            try validateLegacyJournal(record)
            return try recoverLegacy(record, generation: generation)
        }
    }

    private func recoverCurrent(_ input: OwnershipJournal, generation: UInt64) throws -> SafeResult {
        var record = input
        guard record.phase == .verifiedApplied else {
            if try allOwnedGroupsAreBefore(record) {
                try journal.clear()
                return SafeResult(status: .restored, generation: generation)
            }
            return SafeResult(status: .recoveryRequired, generation: generation)
        }
        let services = try configuration.persistentServices()
        let active = try configuration.activeServices(serviceIDs: record.entries.map { $0.serviceID })
        guard Set(services.map { $0.id }).count == services.count else { throw JournalFailure.invalid }
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        var changes: [String: [ProxyGroup: GroupValue]] = [:]
        var conflicts: Set<OwnedGroupID> = []
        var alreadyRestored: Set<OwnedGroupID> = []
        for entry in record.entries {
            guard let service = current[entry.serviceID], let running = active[entry.serviceID],
                  stable(service, running, entry) else {
                conflicts.formUnion(entry.ownedGroups.map { OwnedGroupID(serviceID: entry.serviceID, group: $0) })
                continue
            }
            for group in entry.ownedGroups {
                let id = OwnedGroupID(serviceID: entry.serviceID, group: group)
                if service.groups[group] == entry.written[group],
                   running.groups[group] == entry.written[group] {
                    changes[entry.serviceID, default: [:]][group] = entry.before[group]
                } else if service.groups[group] == entry.before[group],
                          running.groups[group] == entry.before[group] {
                    alreadyRestored.insert(id)
                } else {
                    conflicts.insert(id)
                }
            }
        }
        let conflictCount = conflicts.count
        let count = changes.values.reduce(0) { $0 + $1.count }
        if count == 0 {
            if conflictCount == 0 {
                guard try allOwnedGroupsAreBefore(record) else {
                    return SafeResult(status: .recoveryRequired, generation: generation)
                }
                try journal.clear()
                return SafeResult(status: .restored, generation: generation)
            }
            record.phase = .uncertain
            record.restoration.verifiedRestored = alreadyRestored
            record.restoration.remainingConflicts = conflicts
            try journal.persist(record)
            return SafeResult(status: .conflict, generation: generation, unresolvedGroups: conflictCount)
        }
        let verifiedRecord = record
        record.phase = .uncertain
        record.restoration.remainingConflicts = conflicts
        try journal.persist(record)
        do {
            for id in changes.keys.sorted() {
                guard let entry = record.entries.first(where: { $0.serviceID == id }) else { throw JournalFailure.invalid }
                try configuration.stage(serviceID: id, replacements: changes[id]!,
                                        expected: record.entries.first(where: { $0.serviceID == id })!.written
                                            .filter { changes[id]!.keys.contains($0.key) },
                                        expectedUnownedDigest: entry.persistentUnownedDigest)
            }
            let active = try configuration.activeServices(serviceIDs: Array(changes.keys))
            guard changes.allSatisfy({ id, groups in
                guard let entry = record.entries.first(where: { $0.serviceID == id }),
                      let running = active[id], running.authentication != .present,
                      running.unownedDigest == entry.activeUnownedDigest,
                      validGroups(running.groups) else { return false }
                return groups.keys.allSatisfy { running.groups[$0] == entry.written[$0] }
            }) else { throw BackendFailure.stageFailed }
        } catch {
            try journal.persist(verifiedRecord)
            return SafeResult(status: .failedRolledBack, generation: generation,
                              unresolvedGroups: count + conflictCount)
        }
        do {
            try configuration.commit()
        } catch BackendFailure.commitRejected {
            try journal.persist(verifiedRecord)
            return SafeResult(status: .failedRolledBack, generation: generation,
                              unresolvedGroups: count + conflictCount)
        } catch {
            return SafeResult(status: .recoveryRequired, generation: generation,
                              unresolvedGroups: count + conflictCount)
        }
        do {
            try configuration.apply()
            let after = try configuration.persistentServices()
            let running = try configuration.activeServices(serviceIDs: Array(changes.keys))
            guard Set(after.map { $0.id }).count == after.count else { throw BackendFailure.verificationFailed }
            let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
            for (id, groups) in changes {
                guard let entry = record.entries.first(where: { $0.serviceID == id }),
                      let service = byID[id], let activeService = running[id],
                      stable(service, activeService, entry) else { throw BackendFailure.verificationFailed }
                for (group, value) in groups {
                    guard service.groups[group] == value && activeService.groups[group] == value else {
                        throw BackendFailure.verificationFailed
                    }
                }
            }
        } catch {
            return SafeResult(status: .recoveryRequired, generation: generation,
                              unresolvedGroups: count + conflictCount)
        }
        record.restoration.verifiedRestored = alreadyRestored.union(Set(changes.flatMap { id, groups in
            groups.keys.map { OwnedGroupID(serviceID: id, group: $0) }
        }))
        try validateJournal(record)
        try journal.persist(record)
        if conflictCount > 0 {
            return SafeResult(status: .conflict, generation: generation,
                              changedGroups: count, unresolvedGroups: conflictCount)
        }
        guard try allOwnedGroupsAreBefore(record) else {
            return SafeResult(status: .recoveryRequired, generation: generation,
                              unresolvedGroups: count)
        }
        try journal.clear()
        return SafeResult(status: .restored, generation: generation, changedGroups: count)
    }

    // schema4非verified只允许“已经全量回到before”的零配置写入清理。
    private func allOwnedGroupsAreBefore(_ record: OwnershipJournal) throws -> Bool {
        let services = try configuration.persistentServices()
        guard Set(services.map { $0.id }).count == services.count else { return false }
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let active = try configuration.activeServices(serviceIDs: record.entries.map { $0.serviceID })
        return record.entries.allSatisfy { entry in
            guard let service = current[entry.serviceID], let running = active[entry.serviceID],
                  stable(service, running, entry) else { return false }
            return entry.ownedGroups.allSatisfy {
                service.groups[$0] == entry.before[$0] && running.groups[$0] == entry.before[$0]
            }
        }
    }

    private func stable(_ service: ServiceSnapshot, _ active: ActiveServiceSnapshot,
                        _ entry: JournalEntry) -> Bool {
        service.enabled && service.active && service.hasProxyProtocol &&
        service.authentication != .present && active.authentication != .present &&
        service.unownedDigest == entry.persistentUnownedDigest &&
        active.unownedDigest == entry.activeUnownedDigest &&
        validGroups(service.groups) && validGroups(active.groups)
    }

    private func matchesWritten(_ record: OwnershipJournal) throws -> Bool {
        let services = try configuration.persistentServices()
        guard Set(services.map { $0.id }).count == services.count else { return false }
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let active = try configuration.activeServices(serviceIDs: record.entries.map { $0.serviceID })
        return record.entries.allSatisfy { entry in
            guard let service = current[entry.serviceID], let running = active[entry.serviceID],
                  stable(service, running, entry) else { return false }
            return service.groups == entry.written && running.groups == entry.written
        }
    }

    private func activeBaselineStillMatches(_ record: OwnershipJournal) throws -> Bool {
        let active = try configuration.activeServices(serviceIDs: record.entries.map { $0.serviceID })
        return record.entries.allSatisfy { entry in
            guard let service = active[entry.serviceID] else { return false }
            return service.authentication != .present && service.groups == entry.before &&
                service.unownedDigest == entry.activeUnownedDigest && validGroups(service.groups)
        }
    }

    // legacy v3绝不升级或持久化新来源；只在历史absent合同下恢复written或确认已回到before。
    private func recoverLegacy(_ record: LegacyOwnershipJournalV3, generation: UInt64) throws -> SafeResult {
        guard record.phase == .verifiedApplied else {
            return SafeResult(status: .recoveryRequired, generation: generation)
        }
        let services = try configuration.persistentServices()
        guard Set(services.map { $0.id }).count == services.count else { throw JournalFailure.invalid }
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let active = try configuration.activeServices(serviceIDs: record.entries.map { $0.serviceID })
        var changes: [String: [ProxyGroup: GroupValue]] = [:]
        for entry in record.entries {
            guard let service = current[entry.serviceID], let running = active[entry.serviceID],
                  service.enabled, service.active, service.hasProxyProtocol,
                  service.authentication == .absent, running.authentication == .absent,
                  validGroups(service.groups), validGroups(running.groups) else {
                return SafeResult(status: .recoveryRequired, generation: generation)
            }
            for group in entry.ownedGroups {
                if service.groups[group] == entry.written[group],
                   running.groups[group] == entry.written[group] {
                    changes[entry.serviceID, default: [:]][group] = entry.before[group]
                } else if service.groups[group] != entry.before[group] ||
                            running.groups[group] != entry.before[group] {
                    return SafeResult(status: .recoveryRequired, generation: generation)
                }
            }
        }
        if changes.isEmpty {
            try journal.clear()
            return SafeResult(status: .restored, generation: generation)
        }
        do {
            for id in changes.keys.sorted() {
                guard let service = current[id],
                      let entry = record.entries.first(where: { $0.serviceID == id }) else {
                    throw JournalFailure.invalid
                }
                try configuration.stage(serviceID: id, replacements: changes[id]!,
                                        expected: entry.written
                                            .filter { changes[id]!.keys.contains($0.key) },
                                        expectedUnownedDigest: service.unownedDigest)
            }
            let beforeCommit = try configuration.activeServices(serviceIDs: record.entries.map { $0.serviceID })
            guard record.entries.allSatisfy({ entry in
                guard let service = beforeCommit[entry.serviceID], service.authentication == .absent,
                      validGroups(service.groups) else { return false }
                return entry.ownedGroups.allSatisfy { group in
                    let expected = changes[entry.serviceID]?[group] == nil ? entry.before[group] : entry.written[group]
                    return service.groups[group] == expected
                }
            }) else {
                return SafeResult(status: .failedRolledBack, generation: generation,
                                  unresolvedGroups: changes.values.reduce(0) { $0 + $1.count })
            }
        } catch {
            return SafeResult(status: .failedRolledBack, generation: generation,
                              unresolvedGroups: changes.values.reduce(0) { $0 + $1.count })
        }
        do {
            try configuration.commit()
        } catch BackendFailure.commitRejected {
            return SafeResult(status: .failedRolledBack, generation: generation,
                              unresolvedGroups: changes.values.reduce(0) { $0 + $1.count })
        } catch {
            return SafeResult(status: .recoveryRequired, generation: generation)
        }
        do {
            try configuration.apply()
            let after = Dictionary(uniqueKeysWithValues: try configuration.persistentServices().map { ($0.id, $0) })
            let running = try configuration.activeServices(serviceIDs: record.entries.map { $0.serviceID })
            for entry in record.entries {
                guard let service = after[entry.serviceID], let activeService = running[entry.serviceID],
                      service.enabled, service.active, service.hasProxyProtocol,
                      service.authentication == .absent, activeService.authentication == .absent,
                      validGroups(service.groups), validGroups(activeService.groups) else {
                    throw BackendFailure.verificationFailed
                }
                for group in entry.ownedGroups {
                    guard service.groups[group] == entry.before[group],
                          activeService.groups[group] == entry.before[group] else {
                        throw BackendFailure.verificationFailed
                    }
                }
            }
        } catch {
            return SafeResult(status: .recoveryRequired, generation: generation)
        }
        try journal.clear()
        return SafeResult(status: .restored, generation: generation,
                          changedGroups: changes.values.reduce(0) { $0 + $1.count })
    }

    private func validGroups(_ groups: [ProxyGroup: GroupValue]) -> Bool {
        guard groups.count == ProxyGroup.allCases.count else { return false }
        for key in ProxyGroup.allCases {
            switch (key, groups[key]) {
            case (.http, .manual(let fields)?), (.https, .manual(let fields)?), (.socks, .manual(let fields)?):
                if let port = fields.port, !(1...65535).contains(port) && !(port == 0 && fields.enabled != true) { return false }
                if let host = fields.host, !host.isEmpty {
                    guard host.utf8.count <= 255, host.unicodeScalars.allSatisfy({
                        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]").contains($0)
                    }) else { return false }
                }
            case (.bypass, .bypass(let domains)?):
                if let domains, !ProxyIntent(port: 1, bypass: domains).validate(allowEmptyStoredBypass: true) { return false }
            case (.pac, .automatic(let fields)?), (.wpad, .automatic(let fields)?):
                guard validDigest(fields.unchangedConfigurationDigest) else { return false }
            default: return false
            }
        }
        return true
    }

    private func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func desiredGroups(_ intent: ProxyIntent, before: [ProxyGroup: GroupValue]) -> [ProxyGroup: GroupValue] {
        var result = before
        for group in [ProxyGroup.http, .https] {
            result[group] = .manual(ManualProxy(enabled: true, host: "127.0.0.1", port: intent.port))
        }
        result[.bypass] = .bypass(intent.bypass)
        for group in [ProxyGroup.pac, .wpad] {
            if case .automatic(var fields)? = before[group] {
                fields.enabled = false
                result[group] = .automatic(fields)
            }
        }
        return result
    }

    private func validateJournal(_ record: OwnershipJournal) throws {
        guard record.schemaVersion == 4, record.installOwnerID == journal.installOwnerID,
              record.transactionGeneration > 0, record.endpoint.profile == .credentialBlindHTTPv1,
              record.endpoint.supervisorGeneration > 0, record.endpoint.listenerEpoch > 0,
              record.endpoint.host == "127.0.0.1", record.endpoint.port == record.intent.port,
              record.intent.validate(), !record.entries.isEmpty, record.entries.count <= 256,
              Set(record.entries.map { $0.serviceID }).count == record.entries.count else { throw JournalFailure.invalid }
        try validateEntries(record.entries.map {
            ($0.serviceID, $0.before, $0.written, $0.ownedGroups)
        }, intent: record.intent)
        guard record.entries.allSatisfy({ validDigest($0.persistentUnownedDigest) && validDigest($0.activeUnownedDigest) }) else {
            throw JournalFailure.invalid
        }
        try validateProgress(record.restoration, entries: record.entries.map { ($0.serviceID, $0.ownedGroups) },
                             phase: record.phase)
    }

    private func validateLegacyJournal(_ record: LegacyOwnershipJournalV3) throws {
        guard record.schemaVersion == 3, record.installOwnerID == journal.installOwnerID,
              record.generation > 0, record.intent.validate(), !record.entries.isEmpty,
              record.entries.count <= 256,
              Set(record.entries.map { $0.serviceID }).count == record.entries.count else { throw JournalFailure.invalid }
        try validateEntries(record.entries.map {
            ($0.serviceID, $0.before, $0.written, $0.ownedGroups)
        }, intent: record.intent)
        try validateProgress(record.restoration, entries: record.entries.map { ($0.serviceID, $0.ownedGroups) },
                             phase: record.phase)
    }

    private func validateEntries(_ entries: [(String, [ProxyGroup: GroupValue], [ProxyGroup: GroupValue], Set<ProxyGroup>)],
                                 intent: ProxyIntent) throws {
        for (serviceID, before, written, owned) in entries {
            guard !serviceID.isEmpty, validGroups(before), validGroups(written),
                  written == desiredGroups(intent, before: before),
                  owned == Set(ProxyGroup.allCases.filter { before[$0] != written[$0] }) else {
                throw JournalFailure.invalid
            }
        }
    }

    private func validateProgress(_ progress: RestorationProgress,
                                  entries: [(String, Set<ProxyGroup>)], phase: JournalPhase) throws {
        let owned = Set(entries.flatMap { serviceID, groups in
            groups.map { OwnedGroupID(serviceID: serviceID, group: $0) }
        })
        guard progress.verifiedRestored.isSubset(of: owned),
              progress.remainingConflicts.isSubset(of: owned),
              progress.verifiedRestored.isDisjoint(with: progress.remainingConflicts) else {
            throw JournalFailure.invalid
        }
        if phase != .uncertain && (!progress.verifiedRestored.isEmpty || !progress.remainingConflicts.isEmpty) {
            throw JournalFailure.invalid
        }
    }
}
