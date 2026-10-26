import Darwin

public struct IPv4Interface: Sendable, Hashable {
    public let name: String      // e.g. "en0"
    public let address: String   // dotted quad
    public let netmask: String

    /// True when `ip` is on this interface's subnet.
    public func contains(_ ip: String) -> Bool {
        guard let a = IPv4.parse(address), let m = IPv4.parse(netmask), let b = IPv4.parse(ip) else { return false }
        return a & m == b & m
    }

    /// Conventional gateway guess (`x.y.z.1` within the subnet) — the discovery reply needs *a* value.
    public var assumedGateway: String {
        guard let a = IPv4.parse(address), let m = IPv4.parse(netmask) else { return "0.0.0.0" }
        return IPv4.format((a & m) | 1)
    }
}

enum IPv4 {
    static func parse(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func format(_ value: UInt32) -> String {
        (0..<4).map { String(value >> (24 - 8 * $0) & 0xFF) }.joined(separator: ".")
    }

    static func bytes(_ text: String) -> [UInt8] {
        let value = parse(text) ?? 0
        return (0..<4).map { UInt8(value >> (24 - 8 * $0) & 0xFF) }
    }
}

/// Host network interface lookup (`getifaddrs`).
public enum Interfaces {
    /// IPv4 addresses of interfaces that are up, sorted by interface name.
    public static func ipv4(includeLoopback: Bool = false) -> [IPv4Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var result: [IPv4Interface] = []
        for entry in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let entry, let address = numericHost(entry.pointee.ifa_addr) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            let isUp = flags & IFF_UP != 0
            let isLoopback = flags & IFF_LOOPBACK != 0
            guard isUp, includeLoopback || !isLoopback else { continue }
            let netmask = numericHost(entry.pointee.ifa_netmask) ?? "255.255.255.0"
            result.append(IPv4Interface(name: cString(entry.pointee.ifa_name), address: address, netmask: netmask))
        }
        return result.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }

    /// The interface a reply to `peer` should advertise: same subnet, else the first LAN interface.
    public static func advertised(for peer: String) -> IPv4Interface? {
        let lan = ipv4()
        return lan.first { $0.contains(peer) } ?? lan.first { $0.name.hasPrefix("en") } ?? lan.first
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let sa, sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard status == 0 else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func cString(_ pointer: UnsafePointer<CChar>) -> String {
        String(decoding: UnsafeBufferPointer(start: pointer, count: strlen(pointer)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
