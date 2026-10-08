import Foundation
import Darwin

// 仅native选择路径；测试注入的是.test下全新私有目录，不接受Dart提供路径。
final class ProtectedJournalBackend: JournalBackend {
    private struct Anchor { let parent: Int32; let name: String; let fd: Int32; let device: dev_t; let inode: ino_t }
    private let directory: URL
    private let serial = NSLock()
    private var anchors: [Anchor] = []
    private var descriptors: [Int32] = []
    private var root: Int32 = -1
    private var lockFD: Int32 = -1
    private var owner: UUID?
    private var poison = false
    // 确定性fixture只注入同步失败，不暴露数据、FD或发布授权。
    private let beforeParentDirectorySyncForTesting: (() throws -> Void)?
    private let beforeDirectorySyncForTesting: (() throws -> Void)?
    init(directory: URL? = nil, beforeParentDirectorySyncForTesting: (() throws -> Void)? = nil, beforeDirectorySyncForTesting: (() throws -> Void)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bettbox/proxy-ownership", isDirectory: true)
        self.beforeDirectorySyncForTesting = beforeDirectorySyncForTesting
        self.beforeParentDirectorySyncForTesting = beforeParentDirectorySyncForTesting
    }
    var installOwnerID: UUID {
        serial.lock(); defer { serial.unlock() }
        precondition(owner != nil && lockFD >= 0)
        return owner!
    }
    private func metadata(_ fd: Int32) throws -> stat {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw JournalFailure.unavailable }
        return s
    }
    private func aclIsEmpty(_ fd: Int32) throws -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return true }
            throw JournalFailure.unavailable
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw JournalFailure.invalid }
        var entry: acl_entry_t?
        let code = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        if code == 0 { return false }
        guard errno == EINVAL else { throw JournalFailure.unavailable }
        return true
    }
    private func clearNewACL(_ fd: Int32) throws {
        guard let acl = acl_init(0) else { throw JournalFailure.unavailable }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw JournalFailure.unavailable }
    }
    private func safeAncestorACL(_ fd: Int32) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw JournalFailure.unavailable
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw JournalFailure.invalid }
        var entry: acl_entry_t?
        var selector = ACL_FIRST_ENTRY
        while acl_get_entry(acl, Int32(selector.rawValue), &entry) == 0 {
            selector = ACL_NEXT_ENTRY
            guard let entry else { throw JournalFailure.invalid }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw JournalFailure.unavailable }
            if tag == ACL_EXTENDED_ALLOW {
                var permissions: acl_permset_t?
                guard acl_get_permset(entry, &permissions) == 0, let permissions else { throw JournalFailure.unavailable }
                for permission in [ACL_WRITE_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
                                   ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                    guard acl_get_perm_np(permissions, permission) == 0 else { throw JournalFailure.invalid }
                }
            }
        }
        guard errno == EINVAL else { throw JournalFailure.unavailable }
    }
    private func validateDirectory(_ fd: Int32, privateRoot: Bool) throws {
        let s = try metadata(fd)
        guard s.st_mode & S_IFMT == S_IFDIR, s.st_nlink > 0,
              (s.st_uid == getuid() || (!privateRoot && s.st_uid == 0)),
              s.st_mode & 0o022 == 0 else { throw JournalFailure.invalid }
        if privateRoot {
            guard s.st_mode & 0o777 == 0o700, try aclIsEmpty(fd) else { throw JournalFailure.invalid }
        } else { try safeAncestorACL(fd) }
    }
    private func openDirectory() throws {
        let path = directory.path
        let parts = path.split(separator: "/").map(String.init)
        guard directory.isFileURL, path.hasPrefix("/"), !parts.isEmpty, parts.count <= 64,
              !parts.contains(".."), !parts.contains("."), path.utf8.count <= 4096 else { throw JournalFailure.invalid }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw JournalFailure.unavailable }
        descriptors.append(current); try validateDirectory(current, privateRoot: false)
        for (index, name) in parts.enumerated() {
            var next = openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0 && errno == ENOENT {
                guard mkdirat(current, name, 0o700) == 0 else { throw JournalFailure.unavailable }
                next = openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw JournalFailure.unavailable }
                descriptors.append(next); try clearNewACL(next)
            } else {
                guard next >= 0 else { throw JournalFailure.invalid }
                descriptors.append(next)
            }
            try validateDirectory(next, privateRoot: index == parts.count - 1)
            let s = try metadata(next)
            anchors.append(Anchor(parent: current, name: name, fd: next, device: s.st_dev, inode: s.st_ino))
            current = next
        }
        root = current
        // 既有目录也可能来自同步失败的尝试；发布前确认完整目录链。
        do {
            for anchor in anchors {
                try beforeParentDirectorySyncForTesting?()
                guard fsync(anchor.fd) == 0, fsync(anchor.parent) == 0 else { throw JournalFailure.unavailable }
            }
        } catch {
            poison = true
            throw JournalFailure.unavailable
        }
    }
    private func anchored() throws {
        guard !poison, root >= 0 else { throw JournalFailure.unavailable }
        for (index, anchor) in anchors.enumerated() {
            var s = stat()
            guard fstatat(anchor.parent, anchor.name, &s, AT_SYMLINK_NOFOLLOW) == 0,
                  s.st_dev == anchor.device, s.st_ino == anchor.inode,
                  s.st_mode & S_IFMT == S_IFDIR else { throw JournalFailure.invalid }
            try validateDirectory(anchor.fd, privateRoot: index == anchors.count - 1)
        }
    }
    private func validateFile(_ fd: Int32) throws -> stat {
        let s = try metadata(fd)
        guard s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1,
              s.st_mode & 0o777 == 0o600, try aclIsEmpty(fd) else { throw JournalFailure.invalid }
        return s
    }
    private func readFile(_ name: String, limit: Int) throws -> Data? {
        let fd = openat(root, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw JournalFailure.invalid }
        defer { if close(fd) != 0 { poison = true } }
        let before = try validateFile(fd)
        guard before.st_size >= 0, before.st_size <= limit else { throw JournalFailure.invalid }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; throw JournalFailure.unavailable }
            guard data.count + n <= limit else { throw JournalFailure.invalid }
            data.append(contentsOf: buffer.prefix(n))
        }
        let after = try validateFile(fd)
        var entry = stat()
        guard data.count == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              fstatat(root, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_dev == before.st_dev, entry.st_ino == before.st_ino else { throw JournalFailure.invalid }
        return data
    }
    private func directorySync() throws {
        try beforeDirectorySyncForTesting?()
        guard fsync(root) == 0 else { throw JournalFailure.unavailable }
    }
    private func publish(_ data: Data, name: String, replacing: Bool) throws {
        let temporary = "write-" + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JournalFailure.unavailable }
        var published = false
        defer {
            if close(fd) != 0 { poison = true }
            if !published { _ = unlinkat(root, temporary, 0) }
        }
        try clearNewACL(fd); _ = try validateFile(fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw JournalFailure.unavailable }
                offset += n
            }
        }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw JournalFailure.unavailable }
        try anchored()
        if replacing {
            if let existing = try readFile(name, limit: JournalCoding.limit) {
                guard let owner else { throw JournalFailure.unavailable }
                _ = try JournalCoding.decode(existing, owner: owner)
            }
            guard !poison else { throw JournalFailure.unavailable }
            guard renameat(root, temporary, root, name) == 0 else { throw JournalFailure.unavailable }
        } else {
            // owner ID首次发布不能覆盖已有ID。
            guard linkat(root, temporary, root, name, 0) == 0 else { throw JournalFailure.invalid }
            guard unlinkat(root, temporary, 0) == 0 else { throw JournalFailure.unavailable }
        }
        published = true
        do { try directorySync() } catch { poison = true; throw JournalFailure.unavailable }
    }
    func acquireOwnership() throws {
        serial.lock(); defer { serial.unlock() }
        guard !poison else { throw JournalFailure.unavailable }
        guard lockFD < 0 else { throw JournalFailure.busy }
        do {
            try openDirectory(); try anchored()
            var fd = openat(root, "ownership.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 { lockFD = fd; try clearNewACL(fd) }
            else {
                guard errno == EEXIST else { throw JournalFailure.unavailable }
                fd = openat(root, "ownership.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw JournalFailure.invalid }; lockFD = fd
            }
            _ = try validateFile(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw JournalFailure.busy }
                throw JournalFailure.unavailable
            }
            if let bytes = try readFile("owner.id", limit: 36) {
                guard let string = String(data: bytes, encoding: .utf8), let id = UUID(uuidString: string),
                      string == id.uuidString.lowercased() else { throw JournalFailure.invalid }
                owner = id
            } else {
                var entry = stat()
                if fstatat(root, "journal.json", &entry, AT_SYMLINK_NOFOLLOW) == 0 { throw JournalFailure.invalid }
                guard errno == ENOENT else { throw JournalFailure.unavailable }
                let id = UUID(); try publish(Data(id.uuidString.lowercased().utf8), name: "owner.id", replacing: false)
                owner = id
            }
        } catch {
            closeOwned(); throw error
        }
    }
    private func closeOwned() {
        if lockFD >= 0 { if close(lockFD) != 0 { poison = true }; lockFD = -1 }
        for fd in descriptors.reversed() { if close(fd) != 0 { poison = true } }
        descriptors = []; anchors = []; root = -1; owner = nil
    }
    func releaseOwnership() {
        serial.lock(); defer { serial.unlock() }; closeOwned()
    }
    private func owned() throws -> UUID {
        guard let owner, lockFD >= 0 else { throw JournalFailure.unavailable }
        try anchored()
        let held = try validateFile(lockFD)
        var entry = stat()
        guard fstatat(root, "ownership.lock", &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_dev == held.st_dev, entry.st_ino == held.st_ino else { throw JournalFailure.invalid }
        guard let bytes = try readFile("owner.id", limit: 36),
              bytes == Data(owner.uuidString.lowercased().utf8), !poison else { throw JournalFailure.invalid }
        return owner
    }
    func load() throws -> OwnershipJournal? {
        serial.lock(); defer { serial.unlock() }
        let owner = try owned()
        guard let data = try readFile("journal.json", limit: JournalCoding.limit) else { return nil }
        return try JournalCoding.decode(data, owner: owner)
    }
    func persist(_ journal: OwnershipJournal) throws {
        serial.lock(); defer { serial.unlock() }
        guard journal.installOwnerID == (try owned()) else { throw JournalFailure.invalid }
        try publish(JournalCoding.encode(journal), name: "journal.json", replacing: true)
    }
    func clear() throws {
        serial.lock(); defer { serial.unlock() }
        let owner = try owned()
        guard let data = try readFile("journal.json", limit: JournalCoding.limit) else { return }
        _ = try JournalCoding.decode(data, owner: owner)
        guard !poison else { throw JournalFailure.unavailable }
        guard unlinkat(root, "journal.json", 0) == 0 else { throw JournalFailure.unavailable }
        do { try directorySync() } catch { poison = true; throw JournalFailure.unavailable }
    }
    deinit { closeOwned() }
}
