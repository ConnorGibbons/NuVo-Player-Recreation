import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One answer to an SSDP search.
public struct SSDPResponse: Sendable, Hashable {
    public let address: String
    public let headers: [String: String]   // keys lowercased

    public var location: URL? { headers["location"].flatMap { URL(string: $0) } }
    public var searchTarget: String? { headers["st"] }
    public var usn: String? { headers["usn"] }
    public var server: String? { headers["server"] }
}

/// SSDP discovery over plain UDP sockets.
///
/// Sends M-SEARCH to the multicast group and, optionally, straight to known
/// hosts. Unicast matters on iOS, where multicast needs a special entitlement,
/// and across VLANs.
public enum SSDP {
    public static func search(target: String, rounds: Int = 2, roundDuration: TimeInterval = 2.5,
                              unicastHosts: [String] = []) async -> [SSDPResponse] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let found = searchBlocking(target: target, rounds: rounds,
                                           roundDuration: roundDuration, unicastHosts: unicastHosts)
                continuation.resume(returning: found)
            }
        }
    }

    static func message(target: String) -> [UInt8] {
        let text = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\n"
            + "ST: \(target)\r\n\r\n"
        return Array(text.utf8)
    }

    static func parse(_ text: String, from address: String) -> SSDPResponse? {
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return SSDPResponse(address: address, headers: headers)
    }

    private static func searchBlocking(target: String, rounds: Int, roundDuration: TimeInterval,
                                       unicastHosts: [String]) -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        let payload = message(target: target)
        var seen = Set<String>()   // the DATE header differs per reply, so key on identity
        var ordered: [SSDPResponse] = []
        let capacity = 65_536
        var buffer = [UInt8](repeating: 0, count: capacity)

        for _ in 0..<max(1, rounds) {
            sendDatagram(fd, payload, to: "239.255.255.250", port: 1900)
            for host in unicastHosts {
                sendDatagram(fd, payload, to: host, port: 1900)
            }
            let deadline = Date().addingTimeInterval(roundDuration)
            while Date() < deadline {
                var from = sockaddr_in()
                var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buffer, capacity, 0, sa, &fromLength)
                    }
                }
                guard count > 0 else { continue }   // timeout; keep waiting until the deadline
                let text = String(decoding: buffer[0..<count], as: UTF8.self)
                guard let response = parse(text, from: ipString(from.sin_addr)) else { continue }
                let key = (response.usn ?? "") + "|" + (response.headers["location"] ?? "")
                if seen.insert(key).inserted {
                    ordered.append(response)
                }
            }
        }
        return ordered
    }

    private static func sendDatagram(_ fd: Int32, _ payload: [UInt8], to host: String, port: UInt16) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

func ipString(_ address: in_addr) -> String {
    var address = address
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
    return String(cString: text)
}

public enum LocalAddress {
    /// The local IPv4 address the OS would use to reach `host`.
    /// Needed to build the callback URL for event subscriptions.
    public static func ipv4(toReach host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, host, &remote.sin_addr) == 1 else { return nil }

        // connect() on a UDP socket sends nothing; it only picks a route.
        let connected = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard named == 0 else { return nil }
        let text = ipString(local.sin_addr)
        return text.isEmpty ? nil : text
    }
}
