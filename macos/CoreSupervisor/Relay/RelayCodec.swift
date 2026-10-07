import Foundation

enum RelayError: Error { case invalid, truncated, eof, io, capacity }
enum RelayCodec {
    static let stageLimit = 4096
    static let businessLimit = 10 * 1024 * 1024
    static func generation(_ text: String) throws -> UInt64 {
        guard let value = UInt64(text), value > 0, value <= UInt64(Int64.max), String(value) == text else { throw RelayError.invalid }
        return value
    }
    static func arguments(_ args: [String]) throws -> UInt64 {
        guard args.count == 4, args[1] == "--owned-supervisor-v1", args[2] == "--generation" else { throw RelayError.invalid }
        return try generation(args[3])
    }
    static func stage(_ kind: String, _ generation: UInt64, launch: UUID? = nil, pid: Int32? = nil) -> Data {
        var text = "{\"type\":\"\(kind)\",\"protocol\":1,\"generation\":\(generation)"
        if let launch { text += ",\"launch\":\"\(launch.uuidString.lowercased())\"" }
        if let pid { text += ",\"pid\":\(pid)" }
        return Data((text + "}").utf8)
    }
    static func credit(_ generation: UInt64, sequence: UInt64) -> Data {
        Data("{\"type\":\"relay_credit\",\"protocol\":1,\"generation\":\(generation),\"sequence\":\(sequence)}".utf8)
    }
    static func prepare(_ bytes: Data, generation: UInt64) throws -> UUID {
        let fields = try object(bytes, keys: ["type", "protocol", "generation", "launch"])
        let text = try string(fields["launch"]!)
        guard let launch = UUID(uuidString: text), text == launch.uuidString.lowercased(),
              bytes == stage("prepare_core", generation, launch: launch), bytes.count <= stageLimit else { throw RelayError.invalid }
        return launch
    }
    static func helloOrAck(_ bytes: Data, kind: String, generation: UInt64) throws {
        let fields = try object(bytes, keys: ["type", "protocol", "generation"])
        guard try string(fields["type"]!) == kind else { throw RelayError.invalid }
        try version(fields, generation)
        guard bytes == stage(kind, generation), bytes.count <= stageLimit else { throw RelayError.invalid }
    }
    static func result(_ bytes: Data, generation: UInt64) throws {
        let fields = try object(bytes, keys: ["protocol", "generation", "result"])
        try version(fields, generation)
    }
    static func action(_ bytes: Data, generation: UInt64) throws {
        let fields = try object(bytes, keys: ["protocol", "generation", "action"])
        try version(fields, generation)
        let action = try object(fields["action"]!, keys: ["id", "method", "data"])
        guard try !string(action["id"]!).isEmpty, try !string(action["method"]!).isEmpty else { throw RelayError.invalid }
    }
    private static func version(_ fields: [String: Data], _ generation: UInt64) throws {
        guard fields["protocol"] == Data("1".utf8), fields["generation"] == Data(String(generation).utf8) else { throw RelayError.invalid }
    }
    private static func string(_ bytes: Data) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? String else { throw RelayError.invalid }
        return value
    }
    // JSONSerialization会吞掉重复键；先执行严格词法扫描，保留顶层原始数字。
    static func object(_ bytes: Data, keys: Set<String>) throws -> [String: Data] {
        guard !bytes.isEmpty, bytes.count <= businessLimit, String(data: bytes, encoding: .utf8) != nil else { throw RelayError.invalid }
        var parser = JSONScan(bytes: Array(bytes))
        let fields = try parser.object(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count, Set(fields.keys) == keys else { throw RelayError.invalid }
        return fields
    }
}

private struct JSONScan {
    let bytes: [UInt8]
    var index = 0
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func expect(_ byte: UInt8) throws {
        space(); guard index < bytes.count, bytes[index] == byte else { throw RelayError.invalid }; index += 1
    }
    mutating func quoted() throws -> String {
        space(); let start = index; try expect(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                let raw = Data(bytes[start..<index])
                guard let result = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String else { throw RelayError.invalid }
                return result
            }
            guard byte >= 32 else { throw RelayError.invalid }
            if byte == 92 {
                guard index < bytes.count else { throw RelayError.invalid }
                // 完整转义的合法性由严格JSON字符串解码确认。
                index += 1
            }
        }
        throw RelayError.invalid
    }
    mutating func object(depth: Int) throws -> [String: Data] {
        guard depth < 64 else { throw RelayError.invalid }
        try expect(123); space(); var fields: [String: Data] = [:]
        if index < bytes.count && bytes[index] == 125 { index += 1; return fields }
        while true {
            let key = try quoted(); guard fields[key] == nil else { throw RelayError.invalid }
            try expect(58); space(); let start = index; try value(depth: depth + 1)
            fields[key] = Data(bytes[start..<index]); space()
            guard index < bytes.count else { throw RelayError.invalid }
            if bytes[index] == 125 { index += 1; return fields }
            try expect(44)
        }
    }
    mutating func value(depth: Int) throws {
        guard depth < 64 else { throw RelayError.invalid }; space()
        guard index < bytes.count else { throw RelayError.invalid }
        switch bytes[index] {
        case 123: _ = try object(depth: depth)
        case 34: _ = try quoted()
        case 91:
            index += 1; space()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); space(); guard index < bytes.count else { throw RelayError.invalid }
                if bytes[index] == 93 { index += 1; return }; try expect(44)
            }
        default:
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            let raw = Data(bytes[start..<index])
            guard !raw.isEmpty else { throw RelayError.invalid }
            guard let token = String(data: raw, encoding: .utf8),
                  ["null", "true", "false"].contains(token) || token.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil else { throw RelayError.invalid }
            _ = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        }
    }
}

// 每次只读取当前header/payload所欠字节；不会吞进第二帧。
struct RelayFrameReader {
    private var header = Data()
    private var body = Data()
    private var length: Int?
    var partial: Bool { !header.isEmpty || !body.isEmpty }
    var complete: Bool { length != nil && body.count == length }
    mutating func read(fd: Int32, limit: Int) throws -> Data? {
        if complete { throw RelayError.capacity }
        let count = length.map { $0 - body.count } ?? (4 - header.count)
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        let amount = buffer.withUnsafeMutableBytes { HRRead(fd, $0.baseAddress, $0.count) }
        if amount == -2 { return nil }
        guard amount >= 0 else { throw RelayError.io }
        if amount == 0 { if partial { throw RelayError.truncated }; throw RelayError.eof }
        if length == nil {
            header.append(contentsOf: buffer.prefix(Int(amount)))
            if header.count == 4 {
                let n = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                guard n > 0, UInt64(n) <= UInt64(limit) else { throw RelayError.invalid }
                length = Int(n); body.reserveCapacity(Int(n))
            }
        } else { body.append(contentsOf: buffer.prefix(Int(amount))) }
        if complete { let value = body; self = Self(); return value }
        return nil
    }
}
struct RelayFrameWriter {
    private var bytes: Data?
    private var offset = 0
    var occupied: Bool { bytes != nil }
    mutating func enqueue(_ payload: Data) throws {
        guard bytes == nil, !payload.isEmpty, payload.count <= RelayCodec.businessLimit else { throw RelayError.capacity }
        let n = UInt32(payload.count)
        bytes = Data((0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) + payload; offset = 0
    }
    mutating func write(fd: Int32) throws -> Bool {
        guard let bytes else { return false }
        let amount = bytes.withUnsafeBytes { HRWrite(fd, $0.baseAddress!.advanced(by: offset), min(bytes.count - offset, 65536)) }
        if amount == -2 { return false }; guard amount > 0 else { throw RelayError.io }
        offset += Int(amount)
        if offset == bytes.count { self.bytes = nil; offset = 0; return true }; return false
    }
}
