import Foundation
import SystemConfiguration

struct SCReadOnlyInspection {
    let services: Int
    let enabled: Int
    let active: Int
    let unknownAuthentication: Int
    let preferencesUnchanged: Bool
}

// 由串行ProxyTransaction独占；不创建提权授权，不将系统字典输出到channel。
final class SystemConfigurationBackend: ConfigurationBackend {
    private var preferences: SCPreferences?
    private var staged = false
    private var poison = false
    private let store: SCDynamicStore?
    init() { store = SCDynamicStoreCreate(nil, "Bettbox proxy verification" as CFString, nil, nil) }

    func lock() throws {
        guard !poison else { throw BackendFailure.readFailed }
        guard preferences == nil else { throw BackendFailure.busy }
        guard let session = SCPreferencesCreate(nil, "Bettbox proxy transaction" as CFString, nil) else {
            throw BackendFailure.readFailed
        }
        guard SCPreferencesLock(session, false) else {
            if SCError() == kSCStatusAccessError { throw BackendFailure.permissionDenied }
            if SCError() == kSCStatusLocked { throw BackendFailure.busy }
            throw BackendFailure.readFailed
        }
        preferences = session; staged = false
    }
    func unlockDiscardingStagedChanges() {
        guard let session = preferences else { poison = true; return }
        SCPreferencesSynchronize(session)
        if !SCPreferencesUnlock(session) { poison = true }
        // 丢弃整个session，未commit的暂存不能进入下一事务。
        preferences = nil; staged = false
    }
    private func session() throws -> SCPreferences {
        guard let session = preferences, !poison else { throw BackendFailure.readFailed }
        return session
    }
    private func services(_ session: SCPreferences) throws -> [SCNetworkService] {
        guard let current = SCNetworkSetCopyCurrent(session),
              let list = SCNetworkSetCopyServices(current) as? [SCNetworkService],
              list.count <= 256 else { throw BackendFailure.readFailed }
        return list
    }
    private func activeDictionary(_ id: String) throws -> [String: Any]? {
        guard UUID(uuidString: id) != nil, let store else {
            throw BackendFailure.readFailed
        }
        let key = SCDynamicStoreKeyCreateNetworkServiceEntity(nil, kSCDynamicStoreDomainState, id as CFString, kSCEntNetProxies)
        guard let raw = SCDynamicStoreCopyValue(store, key) else {
            // 缺少运行状态不视为代理已生效，调用者不能用持久配置补齐。
            return nil
        }
        guard let dictionary = raw as? [String: Any] else { throw BackendFailure.readFailed }
        return dictionary
    }
    private func snapshots(_ session: SCPreferences) throws -> [ServiceSnapshot] {
        try services(session).map { service in
            guard let rawID = SCNetworkServiceGetServiceID(service) else { throw BackendFailure.readFailed }
            let id = rawID as String
            let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
            let dictionary: [String: Any]
            if let proxy {
                guard let raw = SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] else { throw BackendFailure.readFailed }
                dictionary = raw
            } else { dictionary = [:] }
            return ServiceSnapshot(id: id, enabled: SCNetworkServiceGetEnabled(service),
                hasProxyProtocol: proxy != nil, authentication: .unknown,
                groups: try SCProxyDictionary.decode(dictionary), active: try activeDictionary(id) != nil)
        }
    }
    func persistentServices() throws -> [ServiceSnapshot] {
        let session = try session()
        guard !staged else { throw BackendFailure.readFailed }
        SCPreferencesSynchronize(session)
        return try snapshots(session)
    }
    func activeGroups(serviceIDs: [String]) throws -> [String: [ProxyGroup: GroupValue]] {
        let session = try session()
        guard serviceIDs.count <= 256, Set(serviceIDs).count == serviceIDs.count else { throw BackendFailure.readFailed }
        let known = Set(try services(session).compactMap { SCNetworkServiceGetServiceID($0) as String? })
        var result: [String: [ProxyGroup: GroupValue]] = [:]
        for id in serviceIDs {
            guard known.contains(id) else { continue }
            if let dictionary = try activeDictionary(id) { result[id] = try SCProxyDictionary.decode(dictionary) }
        }
        return result
    }
    func stage(serviceID: String, replacements: [ProxyGroup: GroupValue]) throws {
        let session = try session()
        guard let service = try services(session).first(where: { (SCNetworkServiceGetServiceID($0) as String?) == serviceID }),
              SCNetworkServiceGetEnabled(service),
              let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
              let raw = SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] else {
            throw BackendFailure.stageFailed
        }
        let merged = try SCProxyDictionary.merging(raw, replacements: replacements)
        guard SCNetworkProtocolSetConfiguration(proxy, merged as CFDictionary) else { throw BackendFailure.stageFailed }
        staged = true
    }
    func commit() throws {
        let session = try session()
        // SDK false未证明未写入，统一保留不确定，不映射commitRejected。
        guard SCPreferencesCommitChanges(session) else { throw BackendFailure.commitUncertain }
        staged = false
    }
    func apply() throws {
        guard SCPreferencesApplyChanges(try session()) else { throw BackendFailure.applyFailed }
    }
    func inspectReadOnly() throws -> SCReadOnlyInspection {
        guard preferences == nil,
              let first = SCPreferencesCreate(nil, "Bettbox read-only inspection" as CFString, nil),
              let before = SCPreferencesGetSignature(first) else { throw BackendFailure.readFailed }
        let values = try snapshots(first)
        guard let last = SCPreferencesCreate(nil, "Bettbox read-only verification" as CFString, nil),
              let after = SCPreferencesGetSignature(last) else { throw BackendFailure.readFailed }
        return SCReadOnlyInspection(services: values.count, enabled: values.filter { $0.enabled }.count,
            active: values.filter { $0.active }.count,
            unknownAuthentication: values.filter { $0.authentication == .unknown }.count,
            preferencesUnchanged: (before as Data) == (after as Data))
    }
}
