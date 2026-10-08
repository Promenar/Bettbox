import Foundation
import CoreFoundation
import CryptoKit
import SystemConfiguration

// 原始字典只能留在原生后端；对外只有固定失败和类型化字段组。
enum SCProxyDictionary {
    static let manual: [ProxyGroup: [String]] = [
        .http: [kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort].map { $0 as String },
        .https: [kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort].map { $0 as String },
        .socks: [kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort].map { $0 as String }
    ]
    static let bypass = kSCPropNetProxiesExceptionsList as String
    static let automatic: [ProxyGroup: String] = [
        .pac: kSCPropNetProxiesProxyAutoConfigEnable as String,
        .wpad: kSCPropNetProxiesProxyAutoDiscoveryEnable as String
    ]
    private static func number(_ raw: Any?) throws -> Int? {
        guard let raw else { return nil }
        guard let n = raw as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(String(cString: n.objCType)),
              let value = Int(n.stringValue) else { throw BackendFailure.readFailed }
        return value
    }
    private static func enabled(_ raw: Any?) throws -> Bool? {
        guard let raw else { return nil }
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        guard let n = try number(raw), n == 0 || n == 1 else { throw BackendFailure.readFailed }
        return n == 1
    }
    private static func host(_ raw: Any?) throws -> String? {
        guard let raw else { return nil }
        guard let s = raw as? String, s.utf8.count <= 255,
              s.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]").contains($0) }) else {
            throw BackendFailure.readFailed
        }
        return s
    }
    static func decode(_ raw: [String: Any]) throws -> [ProxyGroup: GroupValue] {
        var result: [ProxyGroup: GroupValue] = [:]
        for (group, keys) in manual {
            let port = try number(raw[keys[2]])
            let on = try enabled(raw[keys[0]])
            // macOS会保存已禁用入口的零值端口；保留原值，启用入口仍要求有效端口。
            guard port == nil || (1...65535).contains(port!) || (port == 0 && on != true) else { throw BackendFailure.readFailed }
            result[group] = .manual(ManualProxy(enabled: on, host: try host(raw[keys[1]]), port: port))
        }
        if let value = raw[bypass] {
            guard let domains = value as? [String], ProxyIntent(port: 1, bypass: domains).validate(allowEmptyStoredBypass: true) else { throw BackendFailure.readFailed }
            result[.bypass] = .bypass(domains)
        } else { result[.bypass] = .bypass(nil) }
        // 不保存PAC URL或原未知字段；摘要覆盖所有不允许写入的字段。
        let ignored = Set(manual.values.flatMap { $0 } + [bypass] + Array(automatic.values))
        let digest = try fingerprint(raw.filter { !ignored.contains($0.key) })
        for (group, key) in automatic {
            result[group] = .automatic(AutomaticProxy(enabled: try enabled(raw[key]), unchangedConfigurationDigest: digest))
        }
        return result
    }
    static func merging(_ raw: [String: Any], replacements: [ProxyGroup: GroupValue]) throws -> [String: Any] {
        let before = try decode(raw)
        var output = raw
        for (group, value) in replacements {
            // SOCKS不属于此HTTP入口的写入白名单。
            if let keys = manual[group], group != .socks, case .manual(let fields) = value {
                output[keys[0]] = fields.enabled.map { NSNumber(value: $0 ? 1 : 0) }
                output[keys[1]] = fields.host
                output[keys[2]] = fields.port.map { NSNumber(value: $0) }
            } else if group == .bypass, case .bypass(let domains) = value {
                output[bypass] = domains
            } else if let key = automatic[group], case .automatic(let fields) = value,
                      case .automatic(let original)? = before[group],
                      original.unchangedConfigurationDigest == fields.unchangedConfigurationDigest {
                output[key] = fields.enabled.map { NSNumber(value: $0 ? 1 : 0) }
            } else { throw BackendFailure.stageFailed }
        }
        let decoded = try decode(output)
        guard replacements.allSatisfy({ decoded[$0.key] == $0.value }) else { throw BackendFailure.stageFailed }
        return output
    }
    private static func fingerprint(_ raw: [String: Any]) throws -> String {
        var data = Data()
        func append(_ bytes: Data) throws {
            guard data.count + bytes.count <= 262144 else { throw BackendFailure.readFailed }
            data.append(bytes)
        }
        func value(_ raw: Any, depth: Int) throws {
            guard depth <= 16 else { throw BackendFailure.readFailed }
            if let s = raw as? String {
                guard s.utf8.count <= 262144 else { throw BackendFailure.readFailed }
                let bytes = Data(s.utf8)
                try append(Data("s\(bytes.count):".utf8)); try append(bytes)
            } else if let n = raw as? NSNumber {
                guard n.doubleValue.isFinite else { throw BackendFailure.readFailed }
                let tag = CFGetTypeID(n) == CFBooleanGetTypeID() ? "b" : "n"
                let bytes = Data(n.stringValue.utf8)
                try append(Data("\(tag)\(bytes.count):".utf8)); try append(bytes)
            } else if let d = raw as? Data {
                try append(Data("d\(d.count):".utf8)); try append(d)
            } else if let date = raw as? Date {
                try append(Data("t\(date.timeIntervalSinceReferenceDate):".utf8))
            } else if let dict = raw as? [String: Any] {
                guard dict.count <= 1024 else { throw BackendFailure.readFailed }
                try append(Data("m\(dict.count):".utf8))
                for key in dict.keys.sorted() { try value(key, depth: depth + 1); try value(dict[key]!, depth: depth + 1) }
            } else if let list = raw as? [Any] {
                guard list.count <= 1024 else { throw BackendFailure.readFailed }
                try append(Data("a\(list.count):".utf8))
                for item in list { try value(item, depth: depth + 1) }
            } else { throw BackendFailure.readFailed }
        }
        try value(raw, depth: 0)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
