import Foundation
import SystemConfiguration
import Security

// 工厂只在原生事务内部使用，引用与固定SDK参数不进入通道或日志。
protocol SCSessionFactory {
    func createSession() throws -> SCSessionResource
}
protocol SCSessionResource: AnyObject {
    var preferences: SCPreferences? { get }
    func lockWithoutWaiting() throws
    func synchronize()
    func unlock() throws
    func releaseSession()
    func releaseAuthorization() throws
}

// 关闭责任由实际生产入口消费；测试资源不需要伪造原生引用。
final class SCSessionLifecycle {
    private let resource: SCSessionResource
    private var locked = false
    private var closed = false
    init(_ resource: SCSessionResource) { self.resource = resource }
    var preferences: SCPreferences? { resource.preferences }
    func lock() throws {
        guard !closed, !locked else { throw BackendFailure.busy }
        try resource.lockWithoutWaiting()
        locked = true
    }
    func close() throws {
        guard !closed else { return }
        closed = true
        var failure: Error?
        if locked {
            resource.synchronize()
            do { try resource.unlock() } catch { failure = error }
            locked = false
        }
        resource.releaseSession()
        do { try resource.releaseAuthorization() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
    deinit { try? close() }
}

protocol SCSessionConstruction: AnyObject {
    func createAuthorization() throws
    func createSession() throws -> SCSessionResource
    func releaseAuthorization() throws
}
struct AuthorizedSCSessionFactory: SCSessionFactory {
    private let constructionFactory: () -> SCSessionConstruction
    init(constructionFactory: (() -> SCSessionConstruction)? = nil) {
        self.constructionFactory = constructionFactory ?? { NativeSCSessionConstruction() }
    }
    func createSession() throws -> SCSessionResource {
        let construction = constructionFactory()
        do {
            try construction.createAuthorization()
            return try construction.createSession()
        } catch {
            do { try construction.releaseAuthorization() }
            catch { throw BackendFailure.sessionCleanupFailed }
            throw error
        }
    }
}
private func authorizationFailure(_ status: OSStatus) -> BackendFailure {
    if status == errAuthorizationCanceled { return .authorizationCancelled }
    if status == errAuthorizationDenied || status == errAuthorizationInteractionNotAllowed { return .permissionDenied }
    return .readFailed
}
private final class NativeSCSessionConstruction: SCSessionConstruction {
    private var authorization: AuthorizationRef?
    func createAuthorization() throws {
        // SDK将Defaults定义为零；Swift使用导入的选项类型表达同一值。
        let status = AuthorizationCreate(nil, nil, AuthorizationFlags(rawValue: 0), &authorization)
        guard status == errAuthorizationSuccess, authorization != nil else { throw authorizationFailure(status) }
    }
    func createSession() throws -> SCSessionResource {
        guard let authorization else { throw BackendFailure.readFailed }
        guard let preferences = SCPreferencesCreateWithAuthorization(nil,
            "Bettbox proxy transaction" as CFString, nil, authorization) else {
            if SCError() == kSCStatusAccessError { throw BackendFailure.permissionDenied }
            throw BackendFailure.readFailed
        }
        let resource = AuthorizedSCSessionResource(preferences, authorization)
        self.authorization = nil
        return resource
    }
    func releaseAuthorization() throws {
        guard let authorization else { return }
        self.authorization = nil
        guard AuthorizationFree(authorization, AuthorizationFlags(rawValue: 0)) == errAuthorizationSuccess else {
            throw BackendFailure.sessionCleanupFailed
        }
    }
    deinit { try? releaseAuthorization() }
}
private final class AuthorizedSCSessionResource: SCSessionResource {
    private(set) var preferences: SCPreferences?
    private var authorization: AuthorizationRef?
    init(_ preferences: SCPreferences, _ authorization: AuthorizationRef) {
        self.preferences = preferences; self.authorization = authorization
    }
    func lockWithoutWaiting() throws {
        guard let preferences else { throw BackendFailure.readFailed }
        guard SCPreferencesLock(preferences, false) else {
            if SCError() == kSCStatusAccessError { throw BackendFailure.permissionDenied }
            if SCError() == kSCStatusLocked { throw BackendFailure.busy }
            throw BackendFailure.readFailed
        }
    }
    func synchronize() { if let preferences { SCPreferencesSynchronize(preferences) } }
    func unlock() throws {
        guard let preferences, SCPreferencesUnlock(preferences) else { throw BackendFailure.readFailed }
    }
    func releaseSession() { preferences = nil }
    func releaseAuthorization() throws {
        guard let authorization else { return }
        self.authorization = nil
        guard AuthorizationFree(authorization, AuthorizationFlags(rawValue: 0)) == errAuthorizationSuccess else {
            throw BackendFailure.sessionCleanupFailed
        }
    }
    deinit { releaseSession(); try? releaseAuthorization() }
}

struct SCReadOnlyInspection {
    let services: Int
    let enabled: Int
    let active: Int
    let unknownAuthentication: Int
    let preferencesUnchanged: Bool
}

// 由串行ProxyTransaction独占，系统认证由OS处理，不将系统字典输出到通道。
final class SystemConfigurationBackend: ConfigurationBackend {
    private var sessionLifecycle: SCSessionLifecycle?
    private var preferences: SCPreferences? { sessionLifecycle?.preferences }
    private let sessionFactory: SCSessionFactory
    private var staged = false
    private var poison = false
    private let store: SCDynamicStore?
    init(sessionFactory: SCSessionFactory? = nil) {
        self.sessionFactory = sessionFactory ?? AuthorizedSCSessionFactory()
        store = SCDynamicStoreCreate(nil, "Bettbox proxy verification" as CFString, nil, nil)
    }

    func lock() throws {
        guard !poison else { throw BackendFailure.readFailed }
        guard sessionLifecycle == nil else { throw BackendFailure.busy }
        let lifecycle: SCSessionLifecycle
        do { lifecycle = SCSessionLifecycle(try sessionFactory.createSession()) }
        catch {
            if error as? BackendFailure == .sessionCleanupFailed { poison = true }
            throw error
        }
        do { try lifecycle.lock() }
        catch {
            do { try lifecycle.close() } catch { poison = true; throw BackendFailure.sessionCleanupFailed }
            throw error
        }
        sessionLifecycle = lifecycle; staged = false
    }
    func unlockDiscardingStagedChanges() throws {
        guard let lifecycle = sessionLifecycle else { poison = true; throw BackendFailure.sessionCleanupFailed }
        // 丢弃整个session，未commit的暂存不能进入下一事务。
        defer { sessionLifecycle = nil; staged = false }
        do { try lifecycle.close() } catch { poison = true; throw BackendFailure.sessionCleanupFailed }
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
                hasProxyProtocol: proxy != nil, authentication: SCProxyDictionary.authenticationState(dictionary),
                groups: try SCProxyDictionary.decode(dictionary),
                unownedDigest: try SCProxyDictionary.unownedDigest(dictionary),
                active: try activeDictionary(id) != nil)
        }
    }
    func persistentServices() throws -> [ServiceSnapshot] {
        let session = try session()
        guard !staged else { throw BackendFailure.readFailed }
        SCPreferencesSynchronize(session)
        return try snapshots(session)
    }
    func activeServices(serviceIDs: [String]) throws -> [String: ActiveServiceSnapshot] {
        let session = try session()
        guard serviceIDs.count <= 256, Set(serviceIDs).count == serviceIDs.count else { throw BackendFailure.readFailed }
        let known = Set(try services(session).compactMap { SCNetworkServiceGetServiceID($0) as String? })
        var result: [String: ActiveServiceSnapshot] = [:]
        for id in serviceIDs {
            guard known.contains(id) else { continue }
            if let dictionary = try activeDictionary(id) {
                result[id] = ActiveServiceSnapshot(
                    authentication: SCProxyDictionary.authenticationState(dictionary),
                    groups: try SCProxyDictionary.decode(dictionary),
                    unownedDigest: try SCProxyDictionary.unownedDigest(dictionary))
            }
        }
        return result
    }
    func stage(serviceID: String, replacements: [ProxyGroup: GroupValue],
               expected: [ProxyGroup: GroupValue], expectedUnownedDigest: String) throws {
        let session = try session()
        guard let service = try services(session).first(where: { (SCNetworkServiceGetServiceID($0) as String?) == serviceID }),
              SCNetworkServiceGetEnabled(service),
              let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
              let raw = SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] else {
            throw BackendFailure.stageFailed
        }
        let current = try SCProxyDictionary.decode(raw)
        guard Set(replacements.keys) == Set(expected.keys),
              expected.allSatisfy({ current[$0.key] == $0.value }),
              try SCProxyDictionary.unownedDigest(raw) == expectedUnownedDigest else {
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
