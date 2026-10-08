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
        operation(generation) { try self.recoverLocked(generation) }
    }

    func stop(generation: UInt64) -> SafeResult { recover(generation: generation) }

    func start(_ intent: ProxyIntent, generation: UInt64,
               isCurrent: () -> Bool) -> SafeResult {
        operation(generation) {
            guard intent.validate() else { throw FixedFailure(status: .invalidInput) }
            guard isCurrent() else { return SafeResult(status: .cancelled, generation: generation) }
            if let old = try self.journal.load() {
                try self.validateJournal(old)
                if old.phase == .verifiedApplied && old.intent == intent {
                    if try self.matchesWritten(old) {
                        if isCurrent() { return SafeResult(status: .applied, generation: generation) }
                    }
                }
                let recovery = try self.recoverLocked(generation)
                guard recovery.status == .restored || recovery.status == .idle else { return recovery }
            }
            let services = try self.configuration.persistentServices().filter { $0.enabled && $0.active }
            guard !services.isEmpty else { throw FixedFailure(status: .noServices) }
            guard services.count <= 256 else { throw FixedFailure(status: .recoveryRequired) }
            guard Set(services.map { $0.id }).count == services.count else {
                throw FixedFailure(status: .recoveryRequired)
            }
            let running = try self.configuration.activeGroups(serviceIDs: services.map { $0.id })
            var entries: [JournalEntry] = []
            // 全部服务预检完成后才能写 journal 或系统配置。
            for service in services {
                guard service.authentication == .absent else {
                    throw FixedFailure(status: .unsupportedAuthenticatedProxy)
                }
                guard !service.id.isEmpty && service.hasProxyProtocol && self.validGroups(service.groups) else {
                    throw FixedFailure(status: .recoveryRequired)
                }
                // 专用入口不提供SOCKS；必须由持久与运行双读证明其未启用。
                guard case .manual(let storedSOCKS)? = service.groups[.socks],
                      case .manual(let activeSOCKS)? = running[service.id]?[.socks] else {
                    throw FixedFailure(status: .recoveryRequired)
                }
                guard storedSOCKS.enabled != true, activeSOCKS.enabled != true else {
                    throw FixedFailure(status: .unsupportedSOCKSProxy)
                }
                let written = self.desiredGroups(intent, before: service.groups)
                let owned = Set(ProxyGroup.allCases.filter { service.groups[$0] != written[$0] })
                entries.append(JournalEntry(serviceID: service.id, before: service.groups,
                                            written: written, ownedGroups: owned))
            }
            guard isCurrent() else { return SafeResult(status: .cancelled, generation: generation) }
            var record = OwnershipJournal(schemaVersion: 3,
                installOwnerID: self.journal.installOwnerID, generation: generation, transactionID: UUID(),
                intent: intent, phase: .prepared, entries: entries)
            try self.journal.persist(record)
            do {
                for entry in entries {
                    guard isCurrent() else {
                        try self.journal.clear()
                        return SafeResult(status: .cancelled, generation: generation)
                    }
                    if !entry.ownedGroups.isEmpty {
                        try self.configuration.stage(serviceID: entry.serviceID,
                            replacements: entry.written.filter { entry.ownedGroups.contains($0.key) })
                    }
                }
                guard isCurrent() else {
                    try self.journal.clear()
                    return SafeResult(status: .cancelled, generation: generation)
                }
            } catch {
                // 暂存失败，未调用 commit；解锁时后端必须丢弃 session。
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
            // 一旦 commit，取消不能丢下未核验的配置，必须继续核验或保留未决证据。
            record.phase = .committed
            do {
                try self.journal.persist(record)
                try self.configuration.apply()
                guard try self.matchesWritten(record) else {
                    throw BackendFailure.verificationFailed
                }
                record.phase = .verifiedApplied
                try self.journal.persist(record)
            } catch {
                record.phase = .uncertain
                try? self.journal.persist(record)
                return SafeResult(status: .recoveryRequired, generation: generation)
            }
            if !isCurrent() {
                let compensation = try self.recoverLocked(generation)
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
            // 任意底层异常均不能跨出原始正文。
            return SafeResult(status: .recoveryRequired, generation: generation)
        }
    }

    private func recoverLocked(_ generation: UInt64) throws -> SafeResult {
        guard var record = try journal.load() else {
            return SafeResult(status: .idle, generation: generation)
        }
        try validateJournal(record)
        guard record.phase == .verifiedApplied else {
            return SafeResult(status: .recoveryRequired, generation: generation)
        }
        let verifiedRecord = record
        let services = try configuration.persistentServices()
        let active = try configuration.activeGroups(serviceIDs: record.entries.map { $0.serviceID })
        guard Set(services.map { $0.id }).count == services.count else { throw JournalFailure.invalid }
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        var changes: [String: [ProxyGroup: GroupValue]] = [:]
        var conflictGroups: Set<OwnedGroupID> = []
        for entry in record.entries {
            for group in entry.ownedGroups {
                // 新认证配置也是外部变更，不能恢复原 host 或 enable。
                guard let service = current[entry.serviceID], service.enabled,
                      service.hasProxyProtocol, service.authentication == .absent,
                      service.groups[group] == entry.written[group],
                      active[entry.serviceID]?[group] == entry.written[group] else {
                    conflictGroups.insert(OwnedGroupID(serviceID: entry.serviceID, group: group))
                    continue
                }
                changes[entry.serviceID, default: [:]][group] = entry.before[group]
            }
        }
        let conflicts = conflictGroups.count
        let count = changes.values.reduce(0) { $0 + $1.count }
        if count == 0 {
            if conflicts == 0 { try journal.clear(); return SafeResult(status: .restored, generation: generation) }
            record.phase = .uncertain
            record.restoration.remainingConflicts = conflictGroups
            try journal.persist(record)
            return SafeResult(status: .conflict, generation: generation, unresolvedGroups: conflicts)
        }
        // 补偿提交前撤销自动恢复资格，崩溃不能重放旧 verified 标记。
        record.phase = .uncertain
        record.restoration.remainingConflicts = conflictGroups
        try journal.persist(record)
        do {
            for id in changes.keys.sorted() { try configuration.stage(serviceID: id, replacements: changes[id]!) }
        } catch {
            // 尚未 commit，可恢复原 verified 证据，重试仍须双读匹配。
            try journal.persist(verifiedRecord)
            return SafeResult(status: .failedRolledBack, generation: generation, unresolvedGroups: count + conflicts)
        }
        do {
            try configuration.commit()
        } catch BackendFailure.commitRejected {
            try journal.persist(verifiedRecord)
            return SafeResult(status: .failedRolledBack, generation: generation, unresolvedGroups: count + conflicts)
        } catch {
            return SafeResult(status: .recoveryRequired, generation: generation, unresolvedGroups: count + conflicts)
        }
        do {
            try configuration.apply()
            let after = try configuration.persistentServices()
            guard Set(after.map { $0.id }).count == after.count else { throw BackendFailure.verificationFailed }
            let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.groups) })
            let running = try configuration.activeGroups(serviceIDs: Array(changes.keys))
            for (id, groups) in changes {
                for (group, value) in groups {
                    guard byID[id]?[group] == value && running[id]?[group] == value else {
                        throw BackendFailure.verificationFailed
                    }
                }
            }
        } catch {
            return SafeResult(status: .recoveryRequired, generation: generation, unresolvedGroups: count + conflicts)
        }
        // 最终双读通过才登记完成集合，并在返回或 clear 之前持久化。
        record.restoration.verifiedRestored = Set(changes.flatMap { id, groups in
            groups.keys.map { OwnedGroupID(serviceID: id, group: $0) }
        })
        try validateJournal(record)
        try journal.persist(record)
        if conflicts > 0 {
            // 已恢复组不再认领；冲突证据保持 uncertain，只能人工处理。
            return SafeResult(status: .conflict, generation: generation, changedGroups: count, unresolvedGroups: conflicts)
        }
        try journal.clear()
        return SafeResult(status: .restored, generation: generation, changedGroups: count)
    }

    private func matchesWritten(_ record: OwnershipJournal) throws -> Bool {
        let services = try configuration.persistentServices()
        guard Set(services.map { $0.id }).count == services.count else { return false }
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        let active = try configuration.activeGroups(serviceIDs: record.entries.map { $0.serviceID })
        return record.entries.allSatisfy { entry in
            guard let service = current[entry.serviceID], service.enabled, service.hasProxyProtocol,
                  service.authentication == .absent else { return false }
            return service.groups == entry.written && active[entry.serviceID] == entry.written
        }
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
                if let domains = domains, !ProxyIntent(port: 1, bypass: domains).validate(allowEmptyStoredBypass: true) { return false }
            case (.pac, .automatic(let fields)?), (.wpad, .automatic(let fields)?):
                guard fields.unchangedConfigurationDigest.count == 64,
                      fields.unchangedConfigurationDigest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
            default: return false
            }
        }
        return true
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
        guard record.schemaVersion == 3, record.installOwnerID == journal.installOwnerID,
              record.intent.validate(), !record.entries.isEmpty,
              record.entries.count <= 256,
              Set(record.entries.map { $0.serviceID }).count == record.entries.count else { throw JournalFailure.invalid }
        for entry in record.entries {
            guard !entry.serviceID.isEmpty, validGroups(entry.before), validGroups(entry.written),
                  entry.written == desiredGroups(record.intent, before: entry.before),
                  entry.ownedGroups == Set(ProxyGroup.allCases.filter { entry.before[$0] != entry.written[$0] }) else {
                throw JournalFailure.invalid
            }
        }
        let owned = Set(record.entries.flatMap { entry in
            entry.ownedGroups.map { OwnedGroupID(serviceID: entry.serviceID, group: $0) }
        })
        guard record.restoration.verifiedRestored.isSubset(of: owned),
              record.restoration.remainingConflicts.isSubset(of: owned),
              record.restoration.verifiedRestored.isDisjoint(with: record.restoration.remainingConflicts) else {
            throw JournalFailure.invalid
        }
        if record.phase != .uncertain &&
            (!record.restoration.verifiedRestored.isEmpty || !record.restoration.remainingConflicts.isEmpty) {
            throw JournalFailure.invalid
        }
    }
}
