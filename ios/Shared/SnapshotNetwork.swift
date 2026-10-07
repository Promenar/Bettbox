import Foundation
import NetworkExtension
import Darwin

struct IPCIDR {
  let address: String
  let prefix: Int
  let family: Int32

  init(_ text: String, family: Int32) throws {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = Int(parts[1]),
          prefix >= 0, prefix <= (family == AF_INET ? 32 : 128) else {
      throw BettboxNativeError(message: "网络地址或前缀无效")
    }
    var storage = in6_addr()
    guard String(parts[0]).withCString({ inet_pton(family, $0, &storage) }) == 1 else {
      throw BettboxNativeError(message: "网络地址格式无效")
    }
    self.address = String(parts[0])
    self.prefix = prefix
    self.family = family
  }

  var mask: String {
    let value: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    return [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
  }
}

struct SnapshotNetwork: Codable {
  let mtu: Int
  let capacity: Int
  let ipv4Address: String
  let ipv6Address: String
  let dnsServers: [String]
  let includeRoutes: [String]
  let excludeRoutes: [String]
  let includeRoutes6: [String]
  let excludeRoutes6: [String]

  init(_ raw: [String: Any]) throws {
    mtu = (raw["mtu"] as? NSNumber)?.intValue ?? 1480
    capacity = (raw["capacity"] as? NSNumber)?.intValue ?? 256
    ipv4Address = raw["ipv4Address"] as? String ?? "198.18.0.1/30"
    ipv6Address = raw["ipv6Address"] as? String ?? ""
    dnsServers = raw["dnsServers"] as? [String] ?? ["198.18.0.2"]
    includeRoutes = raw["includeRoutes"] as? [String] ?? []
    excludeRoutes = raw["excludeRoutes"] as? [String] ?? []
    includeRoutes6 = raw["includeRoutes6"] as? [String] ?? []
    excludeRoutes6 = raw["excludeRoutes6"] as? [String] ?? []
    try validate()
  }

  func validate() throws {
    guard (1280...65535).contains(mtu), (1...4096).contains(capacity),
          mtu * capacity <= 8 * 1024 * 1024,
          !dnsServers.isEmpty, dnsServers.count <= 8,
          includeRoutes.count + excludeRoutes.count + includeRoutes6.count + excludeRoutes6.count <= 1024 else {
      throw BettboxNativeError(message: "网络配置超过允许范围")
    }
    _ = try IPCIDR(ipv4Address, family: AF_INET)
    if !ipv6Address.isEmpty { _ = try IPCIDR(ipv6Address, family: AF_INET6) }
    for value in includeRoutes + excludeRoutes { _ = try IPCIDR(value, family: AF_INET) }
    for value in includeRoutes6 + excludeRoutes6 { _ = try IPCIDR(value, family: AF_INET6) }
    for server in dnsServers {
      var storage = in6_addr()
      let valid = server.withCString { inet_pton(AF_INET, $0, &storage) == 1 || inet_pton(AF_INET6, $0, &storage) == 1 }
      guard valid else { throw BettboxNativeError(message: "DNS 服务器必须是 IP 地址") }
    }
  }

  func settings() throws -> NEPacketTunnelNetworkSettings {
    try validate()
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let ipv4 = try IPCIDR(ipv4Address, family: AF_INET)
    let v4 = NEIPv4Settings(addresses: [ipv4.address], subnetMasks: [ipv4.mask])
    v4.includedRoutes = try includeRoutes.isEmpty ? [NEIPv4Route.default()] : includeRoutes.map {
      let cidr = try IPCIDR($0, family: AF_INET)
      return NEIPv4Route(destinationAddress: cidr.address, subnetMask: cidr.mask)
    }
    v4.excludedRoutes = try excludeRoutes.map {
      let cidr = try IPCIDR($0, family: AF_INET)
      return NEIPv4Route(destinationAddress: cidr.address, subnetMask: cidr.mask)
    }
    settings.ipv4Settings = v4
    if !ipv6Address.isEmpty {
      let ipv6 = try IPCIDR(ipv6Address, family: AF_INET6)
      let v6 = NEIPv6Settings(addresses: [ipv6.address], networkPrefixLengths: [NSNumber(value: ipv6.prefix)])
      v6.includedRoutes = try includeRoutes6.isEmpty ? [NEIPv6Route.default()] : includeRoutes6.map {
        let cidr = try IPCIDR($0, family: AF_INET6)
        return NEIPv6Route(destinationAddress: cidr.address, networkPrefixLength: NSNumber(value: cidr.prefix))
      }
      v6.excludedRoutes = try excludeRoutes6.map {
        let cidr = try IPCIDR($0, family: AF_INET6)
        return NEIPv6Route(destinationAddress: cidr.address, networkPrefixLength: NSNumber(value: cidr.prefix))
      }
      settings.ipv6Settings = v6
    }
    let dns = NEDNSSettings(servers: dnsServers)
    dns.matchDomains = [""]
    settings.dnsSettings = dns
    settings.mtu = NSNumber(value: mtu)
    return settings
  }
}
