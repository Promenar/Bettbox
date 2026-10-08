import Foundation

// 这些值只在后端与事务内部使用，不允许放入 channel、日志或错误正文。
enum ProxyGroup: String, CaseIterable, Hashable, Codable { case http, https, socks, bypass, pac, wpad }
struct ManualProxy: Equatable, Codable {
    var enabled: Bool?
    var host: String?
    var port: Int?
}
struct AutomaticProxy: Equatable, Codable {
    var enabled: Bool?
    // 不保存 PAC URL；摘要由原生字典适配器内部生成。
    var unchangedConfigurationDigest: String
}
enum GroupValue: Equatable, Codable {
    case manual(ManualProxy)
    case bypass([String]?)
    case automatic(AutomaticProxy)
}
enum AuthenticationState: Equatable { case absent, present, unknown }
struct ActiveServiceSnapshot: Equatable {
    var authentication: AuthenticationState
    var groups: [ProxyGroup: GroupValue]
    var unownedDigest: String
    subscript(_ group: ProxyGroup) -> GroupValue? {
        get { groups[group] }
        set { groups[group] = newValue }
    }
}
struct ServiceSnapshot {
    var id: String
    var enabled: Bool
    var hasProxyProtocol: Bool
    var authentication: AuthenticationState
    var groups: [ProxyGroup: GroupValue]
    var unownedDigest: String
    var active: Bool = true
}
struct ProxyIntent: Equatable, Codable {
    let port: Int
    let bypass: [String]
    func validate(allowEmptyStoredBypass: Bool = false) -> Bool {
        (1...65535).contains(port) && bypass.count <= 256 &&
        bypass.reduce(0) { $0 + $1.utf8.count } <= 4096 &&
        bypass.allSatisfy { (allowEmptyStoredBypass || !$0.isEmpty) && $0.utf8.count <= 255 &&
            !$0.contains("@") && !$0.contains("://") && !$0.contains("?") && !$0.contains("#") &&
            !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    }
}
enum SafeStatus: String {
    case idle, applied, restored, cancelled, conflict, permissionDenied, busy
    case invalidInput, noServices, unsupportedAuthenticatedProxy, unsupportedSOCKSProxy
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
    case permissionDenied, authorizationCancelled, sessionCleanupFailed, busy, readFailed, stageFailed
    // rejected 必须由后端证明没有持久化写入，不能把未知失败映射为此项。
    case commitRejected, commitUncertain, applyFailed, verificationFailed
}
enum JournalFailure: Error { case unavailable, invalid, busy }
enum JournalPhase: String, Equatable, Codable { case prepared, committed, verifiedApplied, uncertain }
enum EndpointProfile: String, Equatable, Codable { case credentialBlindHTTPv1 }
struct EndpointEvidence: Equatable, Codable {
    let profile: EndpointProfile
    let supervisorGeneration: UInt64
    let listenerEpoch: UInt64
    let host: String
    let port: Int
}
// 仅Host可信路径可在内存中发行；不实现Codable，也没有allowUnknown开关。
final class CredentialBlindEndpointCapability {
    let endpoint: EndpointEvidence
    let bypass: [String]
    private let current: () -> Bool

    init?(supervisorGeneration: UInt64, listenerEpoch: UInt64, host: String,
          port: Int, state: String, bypass: [String], current: @escaping () -> Bool) {
        let intent = ProxyIntent(port: port, bypass: bypass)
        guard supervisorGeneration > 0, listenerEpoch > 0, host == "127.0.0.1",
              state == "active", intent.validate() else { return nil }
        endpoint = EndpointEvidence(profile: .credentialBlindHTTPv1,
                                    supervisorGeneration: supervisorGeneration,
                                    listenerEpoch: listenerEpoch, host: host, port: port)
        self.bypass = Array(bypass)
        self.current = current
    }
    var intent: ProxyIntent { ProxyIntent(port: endpoint.port, bypass: bypass) }
    func isCurrent() -> Bool { current() }
}
struct OwnedGroupID: Hashable, Codable {
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
    let persistentUnownedDigest: String
    let activeUnownedDigest: String
}
struct OwnershipJournal: Codable {
    let schemaVersion: Int
    let installOwnerID: UUID
    let transactionGeneration: UInt64
    let transactionID: UUID
    let endpoint: EndpointEvidence
    let intent: ProxyIntent
    var phase: JournalPhase
    // 原始 entries 不可改写；完成证据仅来自恢复后的持久/运行双读。
    var restoration = RestorationProgress()
    let entries: [JournalEntry]
}
struct LegacyJournalEntryV3: Equatable {
    let serviceID: String
    let before: [ProxyGroup: GroupValue]
    let written: [ProxyGroup: GroupValue]
    let ownedGroups: Set<ProxyGroup>
}
struct LegacyOwnershipJournalV3: Codable {
    let schemaVersion: Int
    let installOwnerID: UUID
    let generation: UInt64
    let transactionID: UUID
    let intent: ProxyIntent
    var phase: JournalPhase
    var restoration = RestorationProgress()
    let entries: [LegacyJournalEntryV3]
}
enum LoadedOwnershipJournal {
    case current(OwnershipJournal)
    case legacyV3(LegacyOwnershipJournalV3)

    var installOwnerID: UUID {
        switch self {
        case .current(let value): value.installOwnerID
        case .legacyV3(let value): value.installOwnerID
        }
    }
}

protocol ConfigurationBackend: AnyObject {
    // wait=false，后端必须刷新 session；解锁时丢弃所有未提交暂存。
    func lock() throws
    func unlockDiscardingStagedChanges() throws
    func persistentServices() throws -> [ServiceSnapshot]
    func activeServices(serviceIDs: [String]) throws -> [String: ActiveServiceSnapshot]
    // 新鲜读取后同时核对目标组CAS与未拥有摘要，再只合并指定白名单组。
    func stage(serviceID: String, replacements: [ProxyGroup: GroupValue],
               expected: [ProxyGroup: GroupValue], expectedUnownedDigest: String) throws
    func commit() throws
    func apply() throws
}
protocol JournalBackend: AnyObject {
    var installOwnerID: UUID { get }
    // 应用生命周期锁，不能仅按一次读写加锁；受保护后端持有目录FD与内核文件锁。
    func acquireOwnership() throws
    func releaseOwnership()
    func load() throws -> LoadedOwnershipJournal?
    func persist(_ journal: OwnershipJournal) throws
    func clear() throws
}
