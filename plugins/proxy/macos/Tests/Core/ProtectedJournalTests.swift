import Foundation
import XCTest
import Darwin
@testable import MacosProxyTransactionCore

final class ProtectedJournalTests: XCTestCase {
    private func fixture() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent(".test/three-platform-release/journal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func record(_ owner: UUID, phase: JournalPhase = .verifiedApplied) -> OwnershipJournal {
        let fake = FakeJournal(), config = FakeConfiguration()
        let transaction = ProxyTransaction(configuration: config, journal: fake)
        _ = transaction.start(publicCapability(port: 7890, bypass: ["localhost"]), generation: 1, isCurrent: { true })
        let r = fake.record!
        return OwnershipJournal(schemaVersion: 4, installOwnerID: owner,
            transactionGeneration: r.transactionGeneration, transactionID: r.transactionID,
            endpoint: r.endpoint, intent: r.intent, phase: phase, entries: r.entries)
    }
    private func legacyRecord(_ owner: UUID, phase: JournalPhase = .verifiedApplied) -> LegacyOwnershipJournalV3 {
        let r = record(owner, phase: phase)
        return LegacyOwnershipJournalV3(schemaVersion: 3, installOwnerID: owner,
            generation: r.transactionGeneration, transactionID: r.transactionID,
            intent: r.intent, phase: phase, entries: r.entries.map {
                LegacyJournalEntryV3(serviceID: $0.serviceID, before: $0.before,
                                     written: $0.written, ownedGroups: $0.ownedGroups)
            })
    }
    private func current(_ loaded: LoadedOwnershipJournal?) throws -> OwnershipJournal {
        guard case .current(let value)? = loaded else { throw JournalFailure.invalid }
        return value
    }
    private func writeFixture(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    func testPersistenceReopenAndPermissions() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned")
        let first = ProtectedJournalBackend(directory: path)
        try first.acquireOwnership()
        let owner = first.installOwnerID, original = record(owner)
        try first.persist(original)
        XCTAssertEqual(try JournalCoding.encode(current(first.load())), try JournalCoding.encode(original))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for name in ["ownership.lock", "owner.id", "journal.json"] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        first.releaseOwnership()
        let second = ProtectedJournalBackend(directory: path); defer { second.releaseOwnership() }
        try second.acquireOwnership()
        XCTAssertEqual(second.installOwnerID, owner)
        XCTAssertEqual(try JournalCoding.encode(current(second.load())), try JournalCoding.encode(original))
        try second.clear(); XCTAssertNil(try second.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("ownership.lock").path))
    }
    func testActualJournalWithTransactionRestoresAfterReopen() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned"), config = FakeConfiguration()
        let before = config.services[0].groups
        do {
            let disk = ProtectedJournalBackend(directory: path)
            let transaction = ProxyTransaction(configuration: config, journal: disk)
            XCTAssertEqual(transaction.start(publicCapability(port: 7890, bypass: ["localhost"]), generation: 1, isCurrent: { true }).status, .applied)
            XCTAssertNotNil(try disk.load())
        }
        let disk = ProtectedJournalBackend(directory: path)
        let transaction = ProxyTransaction(configuration: config, journal: disk)
        XCTAssertEqual(transaction.recover(generation: 2).status, .restored)
        XCTAssertEqual(config.services[0].groups, before)
        XCTAssertNil(try disk.load())
        disk.releaseOwnership()
    }
    func testLifetimeLockRejectsSecondInstanceAndOtherProcess() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned"), first = ProtectedJournalBackend(directory: path)
        try first.acquireOwnership(); defer { first.releaseOwnership() }
        try first.persist(record(first.installOwnerID))
        let second = ProtectedJournalBackend(directory: path)
        XCTAssertThrowsError(try second.acquireOwnership()) { XCTAssertEqual(String(describing: $0), "busy") }
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,os,sys\nf=os.open(sys.argv[1],os.O_RDWR|os.O_NOFOLLOW)\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError:\n print('BUSY')\n sys.exit(0)\nsys.exit(7)", path.appendingPathComponent("ownership.lock").path]
        child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(pipe.fileHandleForReading.readDataToEndOfFile(), Data("BUSY\n".utf8))
        try first.clear()
        XCTAssertThrowsError(try second.acquireOwnership())
        first.releaseOwnership()
        try second.acquireOwnership(); second.releaseOwnership()
    }
    func testLinksUnsafeModesAndMissingOwnerAreRejectedWithoutRepair() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned"), disk = ProtectedJournalBackend(directory: path)
        try disk.acquireOwnership()
        let r = record(disk.installOwnerID); try disk.persist(r)
        let journal = path.appendingPathComponent("journal.json"), external = base.appendingPathComponent("public-marker")
        let marker = Data("公开测试标记".utf8); try marker.write(to: external)
        try FileManager.default.removeItem(at: journal)
        XCTAssertEqual(symlink(external.path, journal.path), 0)
        XCTAssertThrowsError(try disk.load()); XCTAssertThrowsError(try disk.persist(r)); XCTAssertThrowsError(try disk.clear())
        XCTAssertEqual(try Data(contentsOf: external), marker)
        try FileManager.default.removeItem(at: journal); try disk.persist(r)
        let alias = base.appendingPathComponent("hardlink")
        XCTAssertEqual(link(journal.path, alias.path), 0); XCTAssertThrowsError(try disk.load())
        try FileManager.default.removeItem(at: alias)
        XCTAssertEqual(chmod(journal.path, 0o644), 0); XCTAssertThrowsError(try disk.load())
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual(chmod(journal.path, 0o600), 0)
        disk.releaseOwnership()
        try FileManager.default.removeItem(at: path.appendingPathComponent("owner.id"))
        XCTAssertThrowsError(try ProtectedJournalBackend(directory: path).acquireOwnership())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("owner.id").path))
    }
    func testDirectoryReplacementAndOwnerMutationRevokeStorageUse() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned"), moved = base.appendingPathComponent("moved")
        let disk = ProtectedJournalBackend(directory: path); try disk.acquireOwnership(); defer { disk.releaseOwnership() }
        try disk.persist(record(disk.installOwnerID))
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try disk.load()); XCTAssertThrowsError(try disk.clear())
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("journal.json").path))
        try FileManager.default.removeItem(at: path); try FileManager.default.moveItem(at: moved, to: path)
        try writeFixture(Data(UUID().uuidString.lowercased().utf8), to: path.appendingPathComponent("owner.id"))
        XCTAssertThrowsError(try disk.load())
    }
    func testSchema4CanonicalCodecRejectsUnknownDuplicatesWrongOwnerSchemaAndOverflow() throws {
        let owner = UUID(), r = record(owner), good = try JournalCoding.encode(r)
        let text = String(data: good, encoding: .utf8)!
        for bad in [Data((" " + text).utf8), Data(text.replacingOccurrences(of: "\"schemaVersion\":4", with: "\"schemaVersion\":2").utf8),
                    Data(text.replacingOccurrences(of: "\"schemaVersion\":4", with: "\"schemaVersion\":4,\"schemaVersion\":4").utf8),
                    Data(("{\"unknown\":true," + text.dropFirst()).utf8), Data(repeating: 120, count: JournalCoding.limit + 1)] {
            XCTAssertThrowsError(try JournalCoding.decode(bad, owner: owner))
        }
        XCTAssertThrowsError(try JournalCoding.decode(good, owner: UUID()))
        var progress = r
        progress.phase = .uncertain
        progress.restoration.verifiedRestored = [OwnedGroupID(serviceID: "public-service", group: .http)]
        progress.restoration.remainingConflicts = [OwnedGroupID(serviceID: "public-service", group: .https)]
        guard case .current(let decoded) = try JournalCoding.decode(JournalCoding.encode(progress), owner: owner) else {
            return XCTFail("schema4必须解码为当前类型")
        }
        XCTAssertEqual(decoded.restoration, progress.restoration)
    }
    func testLegacyV3HasIndependentExactCanonicalCodec() throws {
        let owner = UUID(), legacy = legacyRecord(owner)
        let good = try JournalCoding.encodeLegacyV3(legacy)
        guard case .legacyV3(let decoded) = try JournalCoding.decode(good, owner: owner) else {
            return XCTFail("schema3必须解码为独立历史类型")
        }
        XCTAssertEqual(try JournalCoding.encodeLegacyV3(decoded), good)
        let text = String(data: good, encoding: .utf8)!
        for bad in [Data((" " + text).utf8),
                    Data(text.replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":4").utf8),
                    Data(text.replacingOccurrences(of: "\"schemaVersion\":3", with: "\"schemaVersion\":3,\"schemaVersion\":3").utf8),
                    Data(("{\"endpoint\":{}," + text.dropFirst()).utf8)] {
            XCTAssertThrowsError(try JournalCoding.decode(bad, owner: owner))
        }
    }
    func testMalformedOrOversizedFileCannotBeClearedOrOverwritten() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned"), disk = ProtectedJournalBackend(directory: path)
        try disk.acquireOwnership(); defer { disk.releaseOwnership() }
        let r = record(disk.installOwnerID)
        let journal = path.appendingPathComponent("journal.json")
        for bytes in [Data("{}".utf8), Data(repeating: 120, count: JournalCoding.limit + 1)] {
            try writeFixture(bytes, to: journal)
            XCTAssertThrowsError(try disk.load()); XCTAssertThrowsError(try disk.persist(r)); XCTAssertThrowsError(try disk.clear())
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? NSNumber)?.intValue, bytes.count)
        }
    }
    func testPublishedButSyncFailureReopensAsNonverifiedAndOnlyClearsAllBefore() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned")
        var failSync = false
        let disk = ProtectedJournalBackend(directory: path, beforeDirectorySyncForTesting: {
            if failSync { throw JournalFailure.unavailable }
        })
        try disk.acquireOwnership(); let r = record(disk.installOwnerID, phase: .prepared)
        failSync = true
        XCTAssertThrowsError(try disk.persist(r)); XCTAssertThrowsError(try disk.load())
        disk.releaseOwnership()
        let next = ProtectedJournalBackend(directory: path), config = FakeConfiguration()
        let transaction = ProxyTransaction(configuration: config, journal: next)
        XCTAssertEqual(transaction.recover(generation: 2).status, .restored)
        XCTAssertEqual(config.stages, 0)
        XCTAssertNil(try next.load())
        next.releaseOwnership()
    }
    func testNewDirectoriesSyncParentsBeforeOwnerPublication() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        var sequence: [String] = []
        let disk = ProtectedJournalBackend(directory: base.appendingPathComponent("parent/owned"),
            beforeParentDirectorySyncForTesting: { sequence.append("parent") },
            beforeDirectorySyncForTesting: { sequence.append("publish") })
        try disk.acquireOwnership(); defer { disk.releaseOwnership() }
        XCTAssertEqual(sequence, Array(repeating: "parent", count: base.appendingPathComponent("parent/owned").path.split(separator: "/").count) + ["publish"])
    }
    func testParentSyncFailurePreventsOwnerCreationAndPoisonsBackend() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned")
        let disk = ProtectedJournalBackend(directory: path, beforeParentDirectorySyncForTesting: {
            throw JournalFailure.unavailable
        })
        defer { disk.releaseOwnership() }
        XCTAssertThrowsError(try disk.acquireOwnership())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("owner.id").path))
        XCTAssertThrowsError(try disk.acquireOwnership()) { XCTAssertEqual(String(describing: $0), "unavailable") }
    }
    func testNoStorageAccessBeforeAcquireOrAfterRelease() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let disk = ProtectedJournalBackend(directory: base.appendingPathComponent("owned"))
        XCTAssertThrowsError(try disk.load()); XCTAssertThrowsError(try disk.clear())
        try disk.acquireOwnership(); let r = record(disk.installOwnerID); disk.releaseOwnership()
        XCTAssertThrowsError(try disk.persist(r)); XCTAssertThrowsError(try disk.load())
    }
    func testReopenDirectoryFromFailedSyncMustConfirmParents() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("owned")
        let first = ProtectedJournalBackend(directory: path, beforeParentDirectorySyncForTesting: {
            throw JournalFailure.unavailable
        })
        XCTAssertThrowsError(try first.acquireOwnership())
        first.releaseOwnership()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let second = ProtectedJournalBackend(directory: path, beforeParentDirectorySyncForTesting: {
            throw JournalFailure.unavailable
        })
        defer { second.releaseOwnership() }
        XCTAssertThrowsError(try second.acquireOwnership())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("owner.id").path))
        second.releaseOwnership()
        var confirmations = 0
        let recovered = ProtectedJournalBackend(directory: path, beforeParentDirectorySyncForTesting: {
            confirmations += 1
        })
        try recovered.acquireOwnership(); defer { recovered.releaseOwnership() }
        XCTAssertEqual(confirmations, path.path.split(separator: "/").count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("owner.id").path))
    }
}
