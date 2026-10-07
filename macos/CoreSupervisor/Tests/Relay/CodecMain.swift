import Foundation
import Darwin

private func reject(_ body: () throws -> Void) {
    do { try body(); fatalError("应拒绝") } catch { }
}
@main struct CodecTests {
    static func main() throws {
        let parsedGeneration = try RelayCodec.arguments(["helper", "--owned-supervisor-v1", "--generation", "1"])
        assert(parsedGeneration == 1)
        for text in ["0", "-1", "01", "1.0", "9223372036854775808", "+1"] {
            reject { _ = try RelayCodec.generation(text) }
        }
        reject { _ = try RelayCodec.arguments(["helper", "--owned-supervisor-v1", "--generation", "1", "--identity", "x"]) }
        let launch = UUID(uuidString: "abcdefab-1234-4123-8123-123456789abc")!
        let prepare = RelayCodec.stage("prepare_core", 7, launch: launch)
        let parsedLaunch = try RelayCodec.prepare(prepare, generation: 7)
        assert(parsedLaunch == launch)
        for malformed in [
            "{\"type\":\"prepare_core\",\"protocol\":1,\"generation\":7,\"launch\":\"ABCDEFAB-1234-4123-8123-123456789ABC\"}",
            "{ \"type\":\"prepare_core\",\"protocol\":1,\"generation\":7,\"launch\":\"abcdefab-1234-4123-8123-123456789abc\"}",
            "{\"type\":\"prepare_core\",\"protocol\":1,\"generation\":7,\"generation\":7,\"launch\":\"abcdefab-1234-4123-8123-123456789abc\"}"] {
            reject { _ = try RelayCodec.prepare(Data(malformed.utf8), generation: 7) }
        }
        try RelayCodec.helloOrAck(RelayCodec.stage("hello", 7), kind: "hello", generation: 7)
        reject { try RelayCodec.helloOrAck(RelayCodec.stage("hello", 8), kind: "hello", generation: 7) }
        reject { try RelayCodec.helloOrAck(Data("{ \"type\":\"hello\",\"protocol\":1,\"generation\":7}".utf8), kind: "hello", generation: 7) }
        try RelayCodec.result(Data("{\"protocol\":1,\"generation\":7,\"result\":{\"id\":\"x\"}}".utf8), generation: 7)
        for malformed in [
            "{\"protocol\":1,\"generation\":7,\"result\":{},\"type\":\"relay_credit\"}",
            "{\"protocol\":1,\"generation\":7,\"result\":{},\"result\":{}}",
            "{\"protocol\":1,\"generation\":7,\"result\":{\"x\":1,\"x\":2}}",
            "{\"protocol\":1,\"generation\":7.0,\"result\":null}",
            "{\"protocol\":true,\"generation\":7,\"result\":null}",
            "{\"protocol\":1,\"generation\":7,\"result\":null}{}"] {
            reject { try RelayCodec.result(Data(malformed.utf8), generation: 7) }
        }
        reject { try RelayCodec.result(RelayCodec.credit(7, sequence: 1), generation: 7) }
        var descriptors = [Int32](repeating: -1, count: 2)
        assert(pipe(&descriptors) == 0)
        defer { _ = close(descriptors[0]); _ = close(descriptors[1]) }
        assert(HRConfigure(descriptors[0]) == 0)
        var reader = RelayFrameReader()
        let payload = Data("{}".utf8)
        for byte in [UInt8(2), 0, 0, 0, 123, 125] {
            var b = byte
            assert(HRWrite(descriptors[1], &b, 1) == 1)
            let frame = try reader.read(fd: descriptors[0], limit: 4096)
            if byte == 125 { assert(frame == payload) } else { assert(frame == nil) }
        }
        // 当前帧读完后，后继帧header不能被提前读取。
        var writer = RelayFrameWriter()
        try writer.enqueue(payload)
        reject { try writer.enqueue(payload) }
        while writer.occupied { _ = try writer.write(fd: descriptors[1]) }
        let headerOnly = try reader.read(fd: descriptors[0], limit: 4096)
        assert(headerOnly == nil)
        let framedPayload = try reader.read(fd: descriptors[0], limit: 4096)
        assert(framedPayload == payload)
        for badHeader in [[UInt8(0),0,0,0], [UInt8(1),16,0,0]] {
            var broken = RelayFrameReader()
            badHeader.withUnsafeBytes { assert(HRWrite(descriptors[1], $0.baseAddress, $0.count) == 4) }
            reject { _ = try broken.read(fd: descriptors[0], limit: 4096) }
        }
        reject { try RelayCodec.result(Data([0xff]), generation: 7) }
        print("production codec: passed")
    }
}
