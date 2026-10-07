import Foundation

// 这些值只在后端与事务内部使用，不允许放入 channel、日志或错误正文。
enum ProxyGroup: String, CaseIterable, Hashable { case http, https, socks, bypass, pac, wpad }
struct ManualProxy: Equatable {
    var enabled: Bool?
    var host: String?
    var port: Int?
}
struct AutomaticProxy: Equatable {
    var enabled: Bool?
    // 不保存 PAC URL；摘要必须由未来原生适配器内部生成。
    var unchangedConfigurationDigest: String
}
enum GroupValue: Equatable {
    case manual(ManualProxy)
    case bypass([String]?)
    case automatic(AutomaticProxy)
}
enum AuthenticationState: Equatable { case absent, present, unknown }
struct ServiceSnapshot {
    var id: String
    var enabled: Bool
    var hasProxyProtocol: Bool
    var authentication: AuthenticationState
    var groups: [ProxyGroup: GroupValue]
}
struct ProxyIntent: Equatable {
    let port: Int
    let bypass: [String]
    func validate() -> Bool {
        (1...65535).contains(port) && bypass.count <= 256 &&
        bypass.reduce(0) { $0 + $1.utf8.count } <= 4096 &&
        bypass.allSatisfy { !$0.isEmpty && $0.utf8.count <= 255 &&
            !$0.contains("@") && !$0.contains("://") && !$0.contains("?") && !$0.contains("#") &&
            !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    }
}
enum SafeStatus: String {
    case idle, applied, restored, cancelled, conflict, permissionDenied, busy
    case invalidInput, noServices, unsupportedAuthenticatedProxy
    case failedRolledBack, recoveryRequired
}
// 安全结果仅有固定枚举和数字，不容纳原配置或任意诊断字符串。
struct SafeResult: Equatable {
    let status: SafeStatus
    let generation: UInt64
    var changedGroups: Int = 0
    var unresolvedGroups: Int = 0
}
enum BackendFailure: Error, Equatable {
    case permissionDenied, busy, readFailed, stageFailed
    // rejected 必须由后端证明没有持久化写入，不能把未知失败映射为此项。
    case commitRejected, commitUncertain, applyFailed, verificationFailed
}
enum JournalFailure: Error { case unavailable, invalid, busy }
enum JournalPhase: Equatable { case prepared, committed, verifiedApplied, uncertain }
struct OwnedGroupID: Hashable {
    let serviceID: String
    let group: ProxyGroup
}
struct RestorationProgress: Equatable {
    var verifiedRestored: Set<OwnedGroupID> = []
    var remainingConflicts: Set<OwnedGroupID> = []
}
struct JournalEntry: Equatable {
    let serviceID: String
    let before: [ProxyGroup: GroupValue]
    let written: [ProxyGroup: GroupValue]
    let ownedGroups: Set<ProxyGroup>
}
struct OwnershipJournal {
    let schemaVersion: Int
    let installOwnerID: UUID
    let generation: UInt64
    let transactionID: UUID
    let intent: ProxyIntent
    var phase: JournalPhase
    // 原始 entries 不可改写；完成证据仅来自恢复后的持久/运行双读。
    var restoration = RestorationProgress()
    let entries: [JournalEntry]
}

protocol ConfigurationBackend: AnyObject {
    // wait=false，后端必须刷新 session；解锁时丢弃所有未提交暂存。
    func lock() throws
    func unlockDiscardingStagedChanges()
    func persistentServices() throws -> [ServiceSnapshot]
    func activeGroups(serviceIDs: [String]) throws -> [String: [ProxyGroup: GroupValue]]
    // 只合并指定白名单组到当前配置，保留一切未知字段。
    func stage(serviceID: String, replacements: [ProxyGroup: GroupValue]) throws
    func commit() throws
    func apply() throws
}
protocol JournalBackend: AnyObject {
    var installOwnerID: UUID { get }
    // 应用生命周期锁，不能仅按一次读写加锁；真实路径/权限实现不在草稿内。
    func acquireOwnership() throws
    func releaseOwnership()
    func load() throws -> OwnershipJournal?
    func persist(_ journal: OwnershipJournal) throws
    func clear() throws
}
