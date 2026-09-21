import Foundation
import Darwin

// MARK: - 磁盘卷

struct VolumeInfo: Identifiable, Equatable {
    let name: String
    let mountPoint: String
    let totalBytes: UInt64
    let freeBytes: UInt64
    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    var id: String { mountPoint }
}

/// 用 URL resourceValues 读卷容量(口径与 Finder 一致),根卷 + /Volumes 下的挂载卷。
enum DiskReader {
    static func volumes() -> [VolumeInfo] {
        var paths = ["/"]
        let mounted = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        paths += mounted.filter { !$0.hasPrefix(".") }.map { "/Volumes/\($0)" }

        var result: [VolumeInfo] = []
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let keys: Set<URLResourceKey> = [
                .isVolumeKey, .volumeIsBrowsableKey, .volumeNameKey,
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isVolume == true,
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity,
                  total > 1_000_000_000          // 忽略合成/恢复小分区
            else { continue }

            let free = max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)
            let name = values.volumeName
                ?? (path == "/" ? "Macintosh HD" : URL(fileURLWithPath: path).lastPathComponent)
            result.append(VolumeInfo(name: name, mountPoint: path,
                                     totalBytes: UInt64(total),
                                     freeBytes: UInt64(free)))
        }
        return result
    }
}

// MARK: - 本机 IP

enum LocalIPReader {
    struct Address: Equatable {
        let name: String
        let ip: String
    }

    /// getifaddrs 枚举处于 UP 状态的非回环接口地址,跳过 IPv6 链路本地(fe80)。
    static func addresses() -> [Address] {
        var result: [Address] = []
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else { return [] }
        defer { freeifaddrs(interfaceList) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let ifa = pointer.pointee
            cursor = ifa.ifa_next
            guard let sockaddrPointer = ifa.ifa_addr else { continue }
            let family = sockaddrPointer.pointee.sa_family

            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var ip: String?
            if family == sa_family_t(AF_INET) {
                let addr = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var inAddr = addr.sin_addr
                ip = inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    .map { String(cString: $0) }
            } else if family == sa_family_t(AF_INET6) {
                let addr = sockaddrPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var in6 = addr.sin6_addr
                ip = inet_ntop(AF_INET6, &in6, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    .map { String(cString: $0) }
                if ip?.hasPrefix("fe80") == true { ip = nil }
            }
            guard let ip else { continue }

            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            result.append(Address(name: String(cString: ifa.ifa_name), ip: ip))
        }

        // en* 的 IPv4 排最前,主内网 IP 稳定取第一个。
        func rank(_ address: Address) -> Int {
            if address.name.hasPrefix("en"), address.ip.contains(".") { return 0 }
            if address.ip.contains(".") { return 1 }
            if address.name.hasPrefix("en") { return 2 }
            return 3
        }
        result.sort {
            rank($0) == rank($1) ? ($0.name, $0.ip) < ($1.name, $1.ip) : rank($0) < rank($1)
        }
        return result
    }
}
