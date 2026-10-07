import Foundation
import CryptoKit
import Darwin

private struct SSIFileStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let uid: UInt32
    let size: Int64
    let seconds: Int64
    let nanos: Int64
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; mode = info.st_mode; uid = info.st_uid
        size = info.st_size; seconds = Int64(info.st_mtimespec.tv_sec); nanos = Int64(info.st_mtimespec.tv_nsec)
    }
}

// 固定公开产物读取，所有组件no-follow；不读取argv、环境或任意用户文件。
final class SSIFile {
    private let fd: Int32
    private let parent: Int32
    private let leaf: String
    private let bundle: URL
    private let components: [String]
    private let initial: SSIFileStamp

    init(bundle: URL, components: [String]) throws {
        guard bundle.isFileURL, !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw SSIError.invalidArtifact }
        self.bundle = bundle; self.components = components; self.leaf = components.last!
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw SSIError.invalidArtifact }
        var file: Int32 = -1
        do {
            let all = bundle.pathComponents.filter { $0 != "/" } + Array(components.dropLast())
            for component in all {
                let next = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                guard next >= 0 else { throw SSIError.invalidArtifact }
                close(directory); directory = next
                var info = stat()
                guard fstat(directory, &info) == 0,
                      info.st_uid == 0 || info.st_uid == geteuid(), UInt32(info.st_mode) & 0o022 == 0 else { throw SSIError.invalidArtifact }
            }
            file = leaf.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
            guard file >= 0 else { throw SSIError.invalidArtifact }
            var info = stat()
            guard fstat(file, &info) == 0, UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
                  info.st_uid == geteuid(), UInt32(info.st_mode) & 0o6022 == 0 else { throw SSIError.invalidArtifact }
            fd = file; parent = directory; initial = SSIFileStamp(info)
        } catch {
            if file >= 0 { close(file) }
            close(directory)
            throw SSIError.invalidArtifact
        }
    }

    deinit { close(fd); close(parent) }

    func recheck() throws {
        var now = stat()
        guard fstat(fd, &now) == 0, SSIFileStamp(now) == initial else { throw SSIError.invalidArtifact }
        let current = try SSIFile(bundle: bundle, components: components)
        guard current.initial == initial else { throw SSIError.invalidArtifact }
        var a = stat(), b = stat()
        guard fstat(parent, &a) == 0, fstat(current.parent, &b) == 0,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw SSIError.invalidArtifact }
    }

    func readBounded(maximum: Int) throws -> Data {
        guard initial.size >= 0, initial.size <= Int64(maximum), lseek(fd, 0, SEEK_SET) == 0 else { throw SSIError.invalidArtifact }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximum + 1, 4097))
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw SSIError.invalidArtifact }
            if count == 0 { break }
            guard result.count + count <= maximum else { throw SSIError.invalidArtifact }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard Int64(result.count) == initial.size else { throw SSIError.invalidArtifact }
        try recheck()
        return result
    }

    func sha256() throws -> String {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw SSIError.invalidArtifact }
        var total: Int64 = 0
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw SSIError.invalidArtifact }
            if count == 0 { break }
            total += Int64(count)
            guard total <= initial.size else { throw SSIError.invalidArtifact }
            digest.update(data: Data(buffer.prefix(count)))
        }
        try recheck()
        guard total == initial.size else { throw SSIError.invalidArtifact }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
