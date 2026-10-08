import Foundation

// 字段组与集合采用固定字符串键和稳定顺序，跨进程编码不能依赖Set哈希顺序。
extension JournalEntry: Codable {
    fileprivate enum Keys: String, CodingKey {
        case serviceID, before, written, ownedGroups, persistentUnownedDigest, activeUnownedDigest
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(serviceID, forKey: .serviceID)
        try c.encode(Dictionary(uniqueKeysWithValues: before.map { ($0.key.rawValue, $0.value) }), forKey: .before)
        try c.encode(Dictionary(uniqueKeysWithValues: written.map { ($0.key.rawValue, $0.value) }), forKey: .written)
        try c.encode(ownedGroups.sorted { $0.rawValue < $1.rawValue }, forKey: .ownedGroups)
        try c.encode(persistentUnownedDigest, forKey: .persistentUnownedDigest)
        try c.encode(activeUnownedDigest, forKey: .activeUnownedDigest)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        serviceID = try c.decode(String.self, forKey: .serviceID)
        func groups(_ key: Keys) throws -> [ProxyGroup: GroupValue] {
            let map = try c.decode([String: GroupValue].self, forKey: key)
            guard Set(map.keys) == Set(ProxyGroup.allCases.map { $0.rawValue }) else { throw JournalFailure.invalid }
            return Dictionary(uniqueKeysWithValues: map.map { (ProxyGroup(rawValue: $0.key)!, $0.value) })
        }
        before = try groups(.before); written = try groups(.written)
        let owned = try c.decode([ProxyGroup].self, forKey: .ownedGroups)
        guard Set(owned).count == owned.count else { throw JournalFailure.invalid }
        ownedGroups = Set(owned)
        persistentUnownedDigest = try c.decode(String.self, forKey: .persistentUnownedDigest)
        activeUnownedDigest = try c.decode(String.self, forKey: .activeUnownedDigest)
    }
}

extension LegacyJournalEntryV3: Codable {
    private enum Keys: String, CodingKey { case serviceID, before, written, ownedGroups }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(serviceID, forKey: .serviceID)
        try c.encode(Dictionary(uniqueKeysWithValues: before.map { ($0.key.rawValue, $0.value) }), forKey: .before)
        try c.encode(Dictionary(uniqueKeysWithValues: written.map { ($0.key.rawValue, $0.value) }), forKey: .written)
        try c.encode(ownedGroups.sorted { $0.rawValue < $1.rawValue }, forKey: .ownedGroups)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        serviceID = try c.decode(String.self, forKey: .serviceID)
        func groups(_ key: Keys) throws -> [ProxyGroup: GroupValue] {
            let map = try c.decode([String: GroupValue].self, forKey: key)
            guard Set(map.keys) == Set(ProxyGroup.allCases.map { $0.rawValue }) else { throw JournalFailure.invalid }
            return Dictionary(uniqueKeysWithValues: map.map { (ProxyGroup(rawValue: $0.key)!, $0.value) })
        }
        before = try groups(.before); written = try groups(.written)
        let owned = try c.decode([ProxyGroup].self, forKey: .ownedGroups)
        guard Set(owned).count == owned.count else { throw JournalFailure.invalid }
        ownedGroups = Set(owned)
    }
}

extension RestorationProgress: Codable {
    private enum Keys: String, CodingKey { case verifiedRestored, remainingConflicts }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        func sorted(_ values: Set<OwnedGroupID>) -> [OwnedGroupID] {
            values.sorted { $0.serviceID == $1.serviceID ? $0.group.rawValue < $1.group.rawValue : $0.serviceID < $1.serviceID }
        }
        try c.encode(sorted(verifiedRestored), forKey: .verifiedRestored)
        try c.encode(sorted(remainingConflicts), forKey: .remainingConflicts)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let done = try c.decode([OwnedGroupID].self, forKey: .verifiedRestored)
        let pending = try c.decode([OwnedGroupID].self, forKey: .remainingConflicts)
        guard Set(done).count == done.count, Set(pending).count == pending.count else { throw JournalFailure.invalid }
        verifiedRestored = Set(done); remainingConflicts = Set(pending)
    }
}

enum JournalCoding {
    static let limit = 4 * 1024 * 1024
    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value
    }
    static func encode(_ record: OwnershipJournal) throws -> Data {
        guard record.schemaVersion == 4, record.transactionGeneration > 0,
              record.endpoint.supervisorGeneration > 0, record.endpoint.listenerEpoch > 0,
              record.endpoint.profile == .credentialBlindHTTPv1,
              record.endpoint.host == "127.0.0.1", record.endpoint.port == record.intent.port,
              record.intent.validate(), !record.entries.isEmpty, record.entries.count <= 256,
              Set(record.entries.map { $0.serviceID }).count == record.entries.count else { throw JournalFailure.invalid }
        do {
            let data = try encoder().encode(record)
            guard data.count <= limit else { throw JournalFailure.invalid }
            return data
        } catch { throw JournalFailure.invalid }
    }
    static func encodeLegacyV3(_ record: LegacyOwnershipJournalV3) throws -> Data {
        guard record.schemaVersion == 3, record.generation > 0, record.intent.validate(),
              !record.entries.isEmpty, record.entries.count <= 256,
              Set(record.entries.map { $0.serviceID }).count == record.entries.count else { throw JournalFailure.invalid }
        do {
            let data = try encoder().encode(record)
            guard data.count <= limit else { throw JournalFailure.invalid }
            return data
        } catch { throw JournalFailure.invalid }
    }
    static func decode(_ data: Data, owner: UUID) throws -> LoadedOwnershipJournal {
        guard data.count <= limit else { throw JournalFailure.invalid }
        if let value = try? JSONDecoder().decode(OwnershipJournal.self, from: data),
           value.installOwnerID == owner, (try? encode(value)) == data {
            return .current(value)
        }
        if let value = try? JSONDecoder().decode(LegacyOwnershipJournalV3.self, from: data),
           value.installOwnerID == owner, (try? encodeLegacyV3(value)) == data {
            return .legacyV3(value)
        }
        throw JournalFailure.invalid
    }
}
