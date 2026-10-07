import Foundation
import Security
import Darwin

// 角色由native入口固定，绝不接收外部期望路径/UID/PPID/hash。
final class SSIAppleBackend: SSIBackend {
    private let role: SSIRole
    init(role: SSIRole) { self.role = role }
    private func info(_ code: SecStaticCode) throws -> [String: Any] {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let value = raw as? [String: Any] else { throw SSIError.invalidSignature }; return value
    }
    private func unique(_ info: [String: Any]) throws -> Data {
        guard let value = info[kSecCodeInfoUnique as String] as? Data, !value.isEmpty else { throw SSIError.invalidSignature }; return value
    }
    private func main(_ info: [String: Any]) throws -> URL {
        guard let url = info[kSecCodeInfoMainExecutable as String] as? URL, url.isFileURL else { throw SSIError.invalidSignature }; return url.standardizedFileURL
    }
    private func associated(_ code: SecCode) throws -> SecStaticCode {
        guard SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { throw SSIError.invalidSignature }
        var result: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &result) == errSecSuccess, let value = result else { throw SSIError.invalidSignature }; return value
    }
    private func checked(_ url: URL) throws -> SecStaticCode {
        var result: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &result) == errSecSuccess, let value = result,
              SecStaticCodeCheckValidity(value, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw SSIError.invalidSignature }; return value
    }
    private func selfInfo() throws -> [String: Any] {
        var result: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &result) == errSecSuccess, let value = result else { throw SSIError.invalidSignature }
        return try info(associated(value))
    }
    private func location() throws -> (URL, [String: Any]) {
        let own = try selfInfo(); let executable = try main(own)
        let basename = role == .host ? "Bettbox" : "BettboxCoreSupervisor"
        guard executable.lastPathComponent == basename,
              executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else { throw SSIError.invalidSignature }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { throw SSIError.invalidSignature }
        return (bundle, own)
    }
    private func artifact(_ bundle: URL, basename: String, identifier: String) throws -> SSIArtifact {
        let manifest = try SSIFile(bundle: bundle, components: ["Contents", "Resources", basename + "Identity.json"])
        let file = try SSIFile(bundle: bundle, components: ["Contents", "MacOS", basename])
        let bytes = try manifest.readBounded(maximum: 4096)
        guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(fields.keys) == Set(["schema", "sha256", "identifier", "cdhash", "signingmode"]),
              let sha = fields["sha256"] as? String, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let cd = fields["cdhash"] as? String, cd.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw SSIError.invalidManifest }
        let canonical = "{\"cdhash\": \"\(cd)\", \"identifier\": \"\(identifier)\", \"schema\": 1, \"sha256\": \"\(sha)\", \"signingmode\": \"adhoc\"}\n"
        guard bytes == Data(canonical.utf8), try file.sha256() == sha else { throw SSIError.invalidManifest }
        let signing = try info(checked(bundle.appendingPathComponent("Contents/MacOS/" + basename)))
        guard signing[kSecCodeInfoIdentifier as String] as? String == identifier,
              let flags = signing[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SSIAdhocSignatureMask() != 0,
              try main(signing) == bundle.appendingPathComponent("Contents/MacOS/" + basename).standardizedFileURL else { throw SSIError.invalidSignature }
        let value = SSIArtifact(sha256: sha, identifier: identifier, cliCDHash: cd, staticUnique: try unique(signing))
        try file.recheck(); try manifest.recheck(); return value
    }
    func context() throws -> SSIContext {
        let (bundle, own) = try location()
        let ownStamp = try stamp(getpid())
        let bundleInfo = try info(checked(bundle))
        guard bundleInfo[kSecCodeInfoIdentifier as String] as? String == "com.appshub.bettbox",
              try main(bundleInfo) == bundle.appendingPathComponent("Contents/MacOS/Bettbox").standardizedFileURL else { throw SSIError.invalidSignature }
        let bundleUnique = try unique(bundleInfo)
        let helper = try artifact(bundle, basename: "BettboxCoreSupervisor", identifier: "com.appshub.bettbox.core.supervisor")
        let core = try artifact(bundle, basename: "BettboxCore", identifier: "com.appshub.bettbox.core")
        let host: SSIStamp
        switch role {
        case .host:
            guard own[kSecCodeInfoIdentifier as String] as? String == "com.appshub.bettbox",
                  try unique(own) == bundleUnique else { throw SSIError.invalidSignature }
            host = ownStamp
        case .supervisor:
            guard own[kSecCodeInfoIdentifier as String] as? String == helper.identifier,
                  try unique(own) == helper.staticUnique else { throw SSIError.invalidSignature }
            host = try stamp(ownStamp.parent)
            guard ownStamp.effectiveUID == host.effectiveUID, ownStamp.realUID == host.realUID,
                  try guestUnique(host.pid, kind: .host) == bundleUnique,
                  try stamp(host.pid) == host else { throw SSIError.invalidChild }
        }
        guard try stamp(getpid()) == ownStamp,
              try unique(selfInfo()) == unique(own),
              try unique(info(checked(bundle))) == bundleUnique else { throw SSIError.invalidSignature }
        return SSIContext(host: host, seal: SSISeal(hostBundleUnique: bundleUnique, helperStatic: helper, coreStatic: core))
    }
    func stamp(_ locator: Int32) throws -> SSIStamp {
        var value = proc_bsdinfo()
        let count = withUnsafeMutablePointer(to: &value) { proc_pidinfo(locator, PROC_PIDTBSDINFO, 0, $0, Int32(MemoryLayout<proc_bsdinfo>.size)) }
        return try SSIKernelDecoder.decode(value, count: count, locator: locator)
    }
    func guestUnique(_ locator: Int32, kind: SSIGuest) throws -> Data {
        let before = try stamp(locator)
        let (bundle, _) = try location()
        let basename: String, identifier: String
        switch kind {
        case .host: basename = "Bettbox"; identifier = "com.appshub.bettbox"
        case .supervisor: basename = "BettboxCoreSupervisor"; identifier = "com.appshub.bettbox.core.supervisor"
        case .core: basename = "BettboxCore"; identifier = "com.appshub.bettbox.core"
        }
        let expected = bundle.appendingPathComponent("Contents/MacOS/" + basename).standardizedFileURL
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: locator)] as CFDictionary, SecCSFlags(), &guest) == errSecSuccess,
              let dynamic = guest else { throw SSIError.invalidSignature }
        let signing = try info(associated(dynamic))
        guard signing[kSecCodeInfoIdentifier as String] as? String == identifier, try main(signing) == expected else { throw SSIError.invalidSignature }
        var path = [CChar](repeating: 0, count: Int(SSIPIDPathBufferCapacity()))
        let count = path.withUnsafeMutableBytes { proc_pidpath(locator, $0.baseAddress, UInt32($0.count)) }
        guard count > 0, Int(count) < path.count, let nul = path.firstIndex(of: 0), nul <= Int(count),
              String(bytes: path.prefix(nul).map { UInt8(bitPattern: $0) }, encoding: .utf8) == expected.path,
              try stamp(locator) == before else { throw SSIError.invalidChild }
        return try unique(signing)
    }
}
enum SSIKernelDecoder {
    static func decode(_ value: proc_bsdinfo, count: Int32, locator: Int32) throws -> SSIStamp {
        guard locator > 0, count == Int32(MemoryLayout<proc_bsdinfo>.size), value.pbi_pid == UInt32(locator),
              let parent = Int32(exactly: value.pbi_ppid), value.pbi_status != UInt32(SZOMB),
              value.pbi_start_tvsec > 0, value.pbi_start_tvusec < 1_000_000 else { throw SSIError.invalidChild }
        return SSIStamp(pid: locator, parent: parent, effectiveUID: value.pbi_uid, realUID: value.pbi_ruid,
                        birthSeconds: value.pbi_start_tvsec, birthMicros: value.pbi_start_tvusec)
    }
}

// Runner桥仅使用此固定入口；fake注入只属于独立测试执行器。
func makeSSIHostAuthority() -> SSIAuthority { SSIAuthority(backend: SSIAppleBackend(role: .host)) }
// helper主程序在启动Core之前使用固定角色seal，不把helper当Runner。
func loadSSISupervisorContext() throws -> SSIContext { try SSIAppleBackend(role: .supervisor).context() }
