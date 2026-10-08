import Foundation

// 字段组与集合采用固定字符串键和稳定顺序，跨进程编码不能依赖Set哈希顺序。
extension JournalEntry: Codable {
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
    static func encode(_ record: OwnershipJournal) throws -> Data {
        guard record.schemaVersion == 3, record.generation > 0, record.intent.validate(),
              !record.entries.isEmpty, record.entries.count <= 256,
              Set(record.entries.map { $0.serviceID }).count == record.entries.count else { throw JournalFailure.invalid }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            guard data.count <= limit else { throw JournalFailure.invalid }
            return data
        } catch { throw JournalFailure.invalid }
    }
    static func decode(_ data: Data, owner: UUID) throws -> OwnershipJournal {
        guard data.count <= limit else { throw JournalFailure.invalid }
        do {
            let value = try JSONDecoder().decode(OwnershipJournal.self, from: data)
            // 重编码逐字节相等，拒绝未知字段、重复键和非canonical输入，不输出原文。
            guard value.installOwnerID == owner, try encode(value) == data else { throw JournalFailure.invalid }
            return value
        } catch { throw JournalFailure.invalid }
    }
}
