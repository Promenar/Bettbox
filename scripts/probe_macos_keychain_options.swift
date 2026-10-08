import Foundation
import Security

// 只访问新生成的合成测试键；不查询任何既有业务服务名。
let service = "com.appshub.bettbox.local-development.synthetic-probe"
guard CommandLine.arguments.count == 2,
      let identifier = UUID(uuidString: CommandLine.arguments[1]) else { exit(2) }
let account = identifier.uuidString
let first = Data("public-synthetic-first".utf8)
let second = Data("public-synthetic-second".utf8)

func query(_ sync: Bool, accessibility: Bool = true) -> [CFString: Any] {
    var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                             kSecAttrAccount: account, kSecAttrSynchronizable: sync]
    if accessibility { q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked }
    return q
}

func existence(_ sync: Bool) -> OSStatus {
    SecItemCopyMatching(query(sync) as CFDictionary, nil)
}

func readMatches(_ expected: Data) -> Bool {
    var q = query(false)
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    return status == errSecSuccess && (result as? Data) == expected
}

// 对应锁定Darwin插件的存在检查与失败转false行为。
func pluginStyleWrite(_ value: Data) -> OSStatus {
    let sync = existence(true)
    let exists = sync == errSecSuccess ||
        (sync == errSecItemNotFound && existence(false) == errSecSuccess)
    if exists {
        let update = SecItemUpdate(query(false) as CFDictionary,
                                   [kSecValueData: value] as CFDictionary)
        if update == errSecSuccess { return update }
        _ = SecItemDelete(query(true, accessibility: false) as CFDictionary)
        _ = SecItemDelete(query(false, accessibility: false) as CFDictionary)
    }
    var q = query(false)
    q[kSecValueData] = value
    return SecItemAdd(q as CFDictionary, nil)
}

let empty = SecItemCopyMatching(query(false, accessibility: false) as CFDictionary, nil)
let syncEmpty = SecItemCopyMatching(query(true, accessibility: false) as CFDictionary, nil)
// UUID碰撞或意外存在时不覆盖、不删除。
guard empty == errSecItemNotFound && syncEmpty == errSecItemNotFound else {
    print("{\"new_key_absent\":false}")
    exit(2)
}
let syncBefore = existence(true)
let writeFirst = pluginStyleWrite(first)
let readFirst = readMatches(first)
let writeSecond = pluginStyleWrite(second)
let readSecond = readMatches(second)
let deleteSync = SecItemDelete(query(true, accessibility: false) as CFDictionary)
let deleteLocal = SecItemDelete(query(false, accessibility: false) as CFDictionary)
let absentAfter = SecItemCopyMatching(query(false, accessibility: false) as CFDictionary, nil)
let repeatDeleteSync = SecItemDelete(query(true, accessibility: false) as CFDictionary)
let repeatDelete = SecItemDelete(query(false, accessibility: false) as CFDictionary)
// 对应插件删除的成功与首错判定，不将重复删除的DP错误隐藏。
func pluginDeleteStatus(_ sync: OSStatus, _ local: OSStatus) -> OSStatus {
    if sync == errSecItemNotFound && local == errSecItemNotFound { return errSecSuccess }
    if sync == errSecSuccess || local == errSecSuccess { return errSecSuccess }
    return sync != errSecItemNotFound ? sync : local
}
let report: [String: Any] = [
    "new_key_absent": true,
    "sync_query_status": Int(syncBefore),
    "first_write_status": Int(writeFirst), "first_read_matches": readFirst,
    "overwrite_status": Int(writeSecond), "overwrite_read_matches": readSecond,
    "sync_delete_status": Int(deleteSync), "local_delete_status": Int(deleteLocal),
    "absent_after_delete": absentAfter == errSecItemNotFound,
    "repeat_delete_status": Int(repeatDelete),
    "plugin_delete_status": Int(pluginDeleteStatus(deleteSync, deleteLocal)),
    "plugin_repeat_delete_status": Int(pluginDeleteStatus(repeatDeleteSync, repeatDelete)),
    "real_credentials_accessed": false,
    "scope": "独立合成键的原生查询行为；不代表完整Flutter插件或App验收"
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
