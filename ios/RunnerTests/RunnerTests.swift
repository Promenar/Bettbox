import XCTest
import Darwin
@testable import Runner

final class RunnerTests: XCTestCase {
  func testIPv4MasksAndInvalidPrefixes() throws {
    XCTAssertEqual(try IPCIDR("198.18.0.1/30", family: AF_INET).mask, "255.255.255.252")
    XCTAssertEqual(try IPCIDR("0.0.0.0/0", family: AF_INET).mask, "0.0.0.0")
    XCTAssertEqual(try IPCIDR("192.0.2.1/32", family: AF_INET).mask, "255.255.255.255")
    XCTAssertThrowsError(try IPCIDR("192.0.2.1/33", family: AF_INET))
    XCTAssertThrowsError(try IPCIDR("invalid/24", family: AF_INET))
    XCTAssertThrowsError(try IPCIDR("2001:db8::1/129", family: AF_INET6))
  }

  func testNetworkDefaultsAndIPv6RouteFamilies() throws {
    let defaults = try SnapshotNetwork([:])
    let settings = try defaults.settings()
    XCTAssertEqual(settings.ipv4Settings?.addresses, ["198.18.0.1"])
    XCTAssertEqual(settings.ipv4Settings?.includedRoutes?.count, 1)
    XCTAssertEqual(settings.dnsSettings?.servers, ["198.18.0.2"])
    XCTAssertNil(settings.ipv6Settings)
    let dual = try SnapshotNetwork(["ipv6Address": "fd00::1/126", "excludeRoutes6": ["fe80::/10"]])
    XCTAssertEqual(try dual.settings().ipv6Settings?.excludedRoutes?.first?.destinationNetworkPrefixLength, 10)
    XCTAssertThrowsError(try SnapshotNetwork(["includeRoutes6": ["192.0.2.0/24"]]))
  }

  func testBoundedNetworkAndNumericDNS() {
    XCTAssertThrowsError(try SnapshotNetwork(["mtu": 1279]))
    XCTAssertThrowsError(try SnapshotNetwork(["mtu": 65535, "capacity": 4096]))
    XCTAssertThrowsError(try SnapshotNetwork(["dnsServers": ["example.invalid"]]))
    XCTAssertThrowsError(try SnapshotNetwork(["capacity": 0]))
  }

  func testSnapshotResourcePathsAndRevisions() throws {
    try SnapshotStore.validPath("providers/nodes.yaml")
    for path in ["", "../nodes.yaml", "/nodes.yaml", "providers//nodes", "providers/./nodes", "providers/../nodes", "providers\\nodes", "nodes\0yaml"] {
      XCTAssertThrowsError(try SnapshotStore.validPath(path))
    }
    try SnapshotStore.validRevision("c3da640d-0dcb-4ba0-9186-a7147b0a8e4d")
    XCTAssertThrowsError(try SnapshotStore.validRevision("../../other"))
    XCTAssertThrowsError(try SnapshotStore.validRevision("C3DA640D-0DCB-4BA0-9186-A7147B0A8E4D"))
  }

  func testCoreReplyFailureDoesNotExposeConfiguration() throws {
    XCTAssertEqual(try CoreClient.checkedReply("{\"code\":0,\"data\":true}")["data"] as? Bool, true)
    XCTAssertThrowsError(try CoreClient.checkedReply("{\"code\":-1,\"data\":\"模拟敏感字段\"}")) { error in
      XCTAssertFalse(error.localizedDescription.contains("模拟敏感字段"))
    }
    XCTAssertThrowsError(try CoreClient.checkedReply("invalid-json"))
  }

  func testResourceManifestRejectsExtraFilesLinksAndMutation() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = home.appendingPathComponent("nodes.yaml")
    let bytes = Data("fixture".utf8)
    try bytes.write(to: file)
    let resources = [SnapshotResource(path: "nodes.yaml", size: bytes.count, sha256: SnapshotStore.hash(bytes))]
    try SnapshotStore.validateResources(home, resources: resources)
    let extra = home.appendingPathComponent("extra.yaml")
    try Data("extra".utf8).write(to: extra)
    XCTAssertThrowsError(try SnapshotStore.validateResources(home, resources: resources))
    try FileManager.default.removeItem(at: extra)
    try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: file)
    XCTAssertThrowsError(try SnapshotStore.validateResources(home, resources: resources))
    try FileManager.default.removeItem(at: extra)
    try Data("changed".utf8).write(to: file)
    XCTAssertThrowsError(try SnapshotStore.validateResources(home, resources: resources))
  }

  func testResourceCopyEnforcesActualByteBudget() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    try Data(repeating: 1, count: 1025).write(to: source)
    let rejected = directory.appendingPathComponent("rejected")
    XCTAssertThrowsError(try SnapshotStore.boundedCopy(source, to: rejected, limit: 1024))
    let accepted = directory.appendingPathComponent("accepted")
    XCTAssertEqual(try SnapshotStore.boundedCopy(source, to: accepted, limit: 1025), 1025)
    XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: accepted))
    XCTAssertThrowsError(try SnapshotStore.boundedCopy(source, to: accepted, limit: 1025))
    let caseAlias = directory.appendingPathComponent("ACCEPTED")
    if FileManager.default.fileExists(atPath: caseAlias.path) {
      XCTAssertThrowsError(try SnapshotStore.boundedCopy(source, to: caseAlias, limit: 1025))
    }
  }
}
