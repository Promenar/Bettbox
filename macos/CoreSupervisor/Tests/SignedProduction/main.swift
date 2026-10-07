import Foundation
import CoreFoundation
import Darwin

private struct FixtureFailure: Error {}
private let action = Data("{\"protocol\":1,\"generation\":1,\"action\":{\"id\":\"fixture\",\"method\":\"public_fixture\",\"data\":null}}".utf8)
private let result = Data("{\"protocol\":1,\"generation\":1,\"result\":{\"id\":\"fixture\",\"data\":\"ok\"}}".utf8)
func publicLine(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

// 生产factory的replyQueue为main；执行线程等待，main通过dispatchMain交付真实异步ABI。
private final class PublicSession {
    let native = makeHostSupervisorAuthority()
    private let lock = NSLock()
    private var reservation: [String: Any]?
    private var control: FileHandle?
    private var closed = false
    private var cancelled = false
    var helper: Process?
    private var waited = false
    func call(_ method: String, _ arguments: [String: Any]) throws -> Any? {
        let signal = DispatchSemaphore(value: 0)
        var returned: Result<Any?, HostSupervisorFailure>?
        native.call(method, arguments: arguments) { returned = $0; signal.signal() }
        guard signal.wait(timeout: .now() + 6) == .success, let outcome = returned else { throw FixtureFailure() }
        return try outcome.get()
    }
    func remember(_ fields: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw FixtureFailure() }; reservation = fields
    }
    func attach(_ file: FileHandle) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { file.closeFile(); throw FixtureFailure() }; control = file
    }
    func stop() {
        lock.lock(); cancelled = true
        let fields = reservation
        let file = closed ? nil : control; closed = true
        lock.unlock()
        if let fields {
            native.call("revokeLaunch", arguments: ["launch": fields["launch"]!, "generation": NSNumber(value: 1)]) { _ in }
        }
        file?.closeFile()
    }
    func settle() throws -> Bool {
        guard let helper else { return false }
        stop()
        // 全fixture只等待同一个Foundation Process，绝不killhelper或wait其Core。
        if !waited { helper.waitUntilExit(); waited = true }
        lock.lock(); let fields = reservation; lock.unlock()
        guard let fields else { return false }
        _ = try call("revokeLaunch", ["launch": fields["launch"]!, "generation": NSNumber(value: 1)])
        let raw = try call("confirmStopped", ["launch": fields["launch"]!, "generation": NSNumber(value: 1)])
        guard let boolean = raw as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else { throw FixtureFailure() }
        return helper.terminationReason == .exit && helper.terminationStatus == 0 && boolean.boolValue
    }
}
func readExact(_ file: FileHandle, _ count: Int) throws -> Data {
    var bytes = Data()
    while bytes.count < count {
        let part = file.readData(ofLength: count - bytes.count)
        guard !part.isEmpty else { throw FixtureFailure() }; bytes.append(part)
    }
    return bytes
}
func receive(_ file: FileHandle) throws -> Data {
    let head = try readExact(file, 4)
    let n = head.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    guard n > 0, n <= 4096 else { throw FixtureFailure() }
    return try readExact(file, Int(n))
}
func send(_ file: FileHandle, _ bytes: Data) throws {
    guard !bytes.isEmpty, bytes.count <= 4096 else { throw FixtureFailure() }
    let n = UInt32(bytes.count)
    file.write(Data((0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) + bytes)
}
private func execute(_ session: PublicSession) throws {
    guard let fields = try session.call("reserveSupervisorLaunch", ["generation": NSNumber(value: 1)]) as? [String: Any],
          Set(fields.keys) == Set(["launch", "generation", "path"]),
          let path = fields["path"] as? String, let launchText = fields["launch"] as? String,
          let launch = UUID(uuidString: launchText), launch.uuidString.lowercased() == launchText else { throw FixtureFailure() }
    try session.remember(fields)
    let helper = Process(), input = Pipe(), output = Pipe()
    helper.executableURL = URL(fileURLWithPath: path)
    helper.arguments = ["--owned-supervisor-v1", "--generation", "1"]
    helper.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    helper.standardInput = input; helper.standardOutput = output; helper.standardError = FileHandle.nullDevice
    try session.attach(input.fileHandleForWriting)
    try helper.run(); session.helper = helper
    input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile()
    defer { output.fileHandleForReading.closeFile() }
    guard try receive(output.fileHandleForReading) == RelayCodec.stage("supervisor_ready", 1) else { throw FixtureFailure() }
    guard let helperProof = try session.call("bindSupervisor", ["launch": launchText, "generation": NSNumber(value: 1),
          "pid": NSNumber(value: helper.processIdentifier)]) as? [String: Any], let helperHandle = helperProof["handle"] as? String else { throw FixtureFailure() }
    try send(input.fileHandleForWriting, RelayCodec.stage("prepare_core", 1, launch: launch))
    let ready = try receive(output.fileHandleForReading)
    _ = try RelayCodec.object(ready, keys: ["type", "protocol", "generation", "launch", "pid"])
    guard let stage = try JSONSerialization.jsonObject(with: ready) as? [String: Any],
          let number = stage["pid"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let pid = Int32(number.stringValue), pid > 0,
          ready == RelayCodec.stage("core_ready", 1, launch: launch, pid: pid) else { throw FixtureFailure() }
    guard let coreProof = try session.call("bindCoreChain", ["handle": helperHandle, "pid": NSNumber(value: pid)]) as? [String: Any],
          let coreHandle = coreProof["handle"] as? String else { throw FixtureFailure() }
    guard let checked = try session.call("recheckCoreChain", ["handle": coreHandle]) as? [String: Any],
          let valid = checked["valid"] as? NSNumber, CFGetTypeID(valid) == CFBooleanGetTypeID(), valid.boolValue else { throw FixtureFailure() }
    try send(input.fileHandleForWriting, RelayCodec.stage("hello", 1))
    guard try receive(output.fileHandleForReading) == RelayCodec.stage("ack", 1) else { throw FixtureFailure() }
    publicLine("HANDSHAKE_OK")
    try send(input.fileHandleForWriting, action)
    let first = try receive(output.fileHandleForReading), second = try receive(output.fileHandleForReading)
    let credit = RelayCodec.credit(1, sequence: 1)
    guard (first == credit && second == result) || (first == result && second == credit) else { throw FixtureFailure() }
    publicLine("CREDIT_RESULT_OK")
    guard try session.settle() else { throw FixtureFailure() }
    publicLine("STOP0_NATIVE_GONE")
}
if CommandLine.arguments.count != 1 { exit(64) }
HRIgnorePipeSignal()
private let session = PublicSession()
// 外部监督只发送EOF；本fixture不把外部timeout变成跨进程kill许可。
DispatchQueue.global().async {
    var byte: UInt8 = 0
    while true {
        let amount = Darwin.read(STDIN_FILENO, &byte, 1)
        if amount < 0 && errno == EINTR { continue }
        if amount == 0 { session.stop(); return }
        if amount < 0 || amount > 0 { session.stop(); return }
    }
}
DispatchQueue.global().async {
    do { try execute(session); publicLine("FIXTURE_OK"); exit(0) }
    catch {
        session.stop()
        // 未捕获Core出生的情况不声称gone；任何失败均保守非零。
        if session.helper != nil { _ = try? session.settle() }
        publicLine("FIXTURE_REJECTED"); exit(70)
    }
}
dispatchMain()
