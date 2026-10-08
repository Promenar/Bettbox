import Foundation
import XCTest
import SystemConfiguration
@testable import MacosProxyTransactionCore

final class SCProxyDictionaryTests: XCTestCase {
    func testHTTPMergePreservesUnknownAuthenticationAndAutomaticFields() throws {
        let raw: [String: Any] = ["HTTPEnable": 0, "HTTPProxy": "proxy.example", "HTTPPort": 8080,
            "HTTPUser": "公开虚构用户名", "PublicUnknown": ["nested": "保留"],
            "SOCKSEnable": 0, "SOCKSProxy": "socks.example", "SOCKSPort": 1080,
            "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://public.example/pac"]
        let before = try SCProxyDictionary.decode(raw)
        guard case .automatic(var pac)? = before[.pac] else { return XCTFail("字段组缺失") }
        pac.enabled = false
        let output = try SCProxyDictionary.merging(raw, replacements: [
            .http: .manual(ManualProxy(enabled: true, host: "127.0.0.1", port: 7890)), .pac: .automatic(pac)])
        for key in ["HTTPUser", "PublicUnknown", "SOCKSEnable", "SOCKSProxy", "SOCKSPort", "ProxyAutoConfigURLString"] {
            XCTAssertTrue(NSDictionary(dictionary: [key: raw[key]!]).isEqual(to: [key: output[key]!]))
        }
        XCTAssertEqual(try SCProxyDictionary.decode(output)[.pac], .automatic(pac))
        XCTAssertThrowsError(try SCProxyDictionary.merging(raw, replacements: [.socks: before[.socks]!]))
    }
    func testMissingFieldsRestoreByRemoval() throws {
        let empty = try SCProxyDictionary.decode([:])
        let applied = try SCProxyDictionary.merging(["PublicUnknown": "保留"], replacements: [
            .http: .manual(ManualProxy(enabled: true, host: "127.0.0.1", port: 7890)), .bypass: .bypass([])])
        let restored = try SCProxyDictionary.merging(applied, replacements: [.http: empty[.http]!, .bypass: empty[.bypass]!])
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored["PublicUnknown"] as? String, "保留")
    }
    func testRejectsTypePollutionCredentialHostsAndInvalidPorts() {
        for raw: [String: Any] in [["HTTPEnable": "1"], ["HTTPEnable": 2], ["HTTPPort": true],
            ["HTTPPort": 1.5], ["HTTPEnable": 1, "HTTPPort": 0], ["HTTPProxy": "user:public@proxy.example"],
            ["ExceptionsList": ["a", 1]]] {
            XCTAssertThrowsError(try SCProxyDictionary.decode(raw))
        }
    }
    func testDisabledZeroPortIsPreservedThroughApplyAndRestore() throws {
        for enabled: Int? in [nil, 0] {
            var raw: [String: Any] = ["HTTPPort": 0]
            if let enabled { raw["HTTPEnable"] = enabled }
            let before = try SCProxyDictionary.decode(raw)
            let applied = try SCProxyDictionary.merging(raw, replacements: [.http: .manual(ManualProxy(enabled: true, host: "127.0.0.1", port: 7890))])
            let restored = try SCProxyDictionary.merging(applied, replacements: [.http: before[.http]!])
            XCTAssertTrue(NSDictionary(dictionary: raw).isEqual(to: restored))
        }
    }
    func testStoredEmptyBypassIsPreservedButRejectedAsNewIntent() throws {
        let raw: [String: Any] = ["ExceptionsList": ["", "localhost"]]
        let before = try SCProxyDictionary.decode(raw)
        let applied = try SCProxyDictionary.merging(raw, replacements: [.bypass: .bypass(["localhost"])])
        let restored = try SCProxyDictionary.merging(applied, replacements: [.bypass: before[.bypass]!])
        XCTAssertTrue(NSDictionary(dictionary: raw).isEqual(to: restored))
        XCTAssertFalse(ProxyIntent(port: 7890, bypass: [""]).validate())
    }
    func testDigestOrderIndependentAndProtectsAutomaticConfiguration() throws {
        let first: [String: Any] = ["ProxyAutoConfigURLString": "https://public.example/a", "Unknown": ["b": 1, "a": 2]]
        let second: [String: Any] = ["Unknown": ["a": 2, "b": 1], "ProxyAutoConfigURLString": "https://public.example/a"]
        XCTAssertEqual(try SCProxyDictionary.decode(first), try SCProxyDictionary.decode(second))
        var changed = second; changed["ProxyAutoConfigURLString"] = "https://public.example/b"
        let before = try SCProxyDictionary.decode(first)
        XCTAssertThrowsError(try SCProxyDictionary.merging(changed, replacements: [.pac: before[.pac]!]))
        XCTAssertThrowsError(try SCProxyDictionary.decode(["Unknown": String(repeating: "x", count: 262145)]))
    }
    func testActualSDKReadOnlyInspection() throws {
        var disabledZero = 0, enabledZero = 0
        var bypassType = 0, bypassEmpty = 0, bypassTokens = 0, bypassControls = 0, bypassOverLimit = 0
        if let preferences = SCPreferencesCreate(nil, "Bettbox read-only port classification" as CFString, nil),
           let set = SCNetworkSetCopyCurrent(preferences),
           let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] {
            for service in services {
                guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                      let raw = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] else { continue }
                if let value = raw[SCProxyDictionary.bypass] {
                    if let domains = value as? [String] {
                        bypassEmpty += domains.filter { $0.isEmpty }.count
                        bypassTokens += domains.filter { $0.contains("@") || $0.contains("://") || $0.contains("?") || $0.contains("#") }.count
                        bypassControls += domains.filter { $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }.count
                        if domains.count > 256 || domains.reduce(0, { $0 + $1.utf8.count }) > 4096 || domains.contains(where: { $0.utf8.count > 255 }) { bypassOverLimit += 1 }
                    } else { bypassType += 1 }
                }
                for keys in SCProxyDictionary.manual.values {
                    if let port = raw[keys[2]] as? NSNumber, port.intValue == 0 {
                        if (raw[keys[0]] as? NSNumber)?.intValue == 1 { enabledZero += 1 }
                        else { disabledZero += 1 }
                    }
                }
            }
        }
        print("SC_ZERO_PORT_CLASSIFICATION disabled=\(disabledZero) enabled=\(enabledZero)")
        print("SC_BYPASS_CLASSIFICATION wrong_type=\(bypassType) empty=\(bypassEmpty) special_tokens=\(bypassTokens) controls=\(bypassControls) over_limit=\(bypassOverLimit)")
        let report = try SystemConfigurationBackend().inspectReadOnly()
        XCTAssertEqual(report.unknownAuthentication, report.services)
        XCTAssertLessThanOrEqual(report.active, report.services)
        XCTAssertTrue(report.preferencesUnchanged)
        // 只输出数量；不输出服务ID、主机、PAC、认证字段或系统字典。
        print("SC_READ_ONLY services=\(report.services) enabled=\(report.enabled) active=\(report.active) unknown_auth=\(report.unknownAuthentication) unchanged=\(report.preferencesUnchanged)")
    }
}
