import Foundation
import Darwin
import IOKit.ps

// MARK: - 网络速率

/// 一次网络采样的结果:全机上下行速率 + 按网卡的拆分。
struct NetSnapshot {
    var inPerSec: Double = 0
    var outPerSec: Double = 0
    var interfaces: [(name: String, inPerSec: Double, outPerSec: Double)] = []
}

/// 通过 sysctl NET_RT_IFLIST2 读每块网卡的累计字节数,相邻两次采样求差
/// 得出速率。只在采样串行队列上使用。
final class NetworkSampler {
    private var lastTotalIn: UInt64 = 0
    private var lastTotalOut: UInt64 = 0
    private var lastPerInterface: [String: (UInt64, UInt64)] = [:]
    private var lastDate: Date?

    func sample(now: Date = Date()) -> NetSnapshot {
        var snapshot = NetSnapshot()
        let counters = Self.interfaceCounters()
        let elapsed = lastDate.map { now.timeIntervalSince($0) } ?? 0

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        for c in counters {
            totalIn += c.bytesIn
            totalOut += c.bytesOut
        }
        if elapsed > 0.05 {
            snapshot.inPerSec = max(0, Double(totalIn - lastTotalIn) / elapsed)
            snapshot.outPerSec = max(0, Double(totalOut - lastTotalOut) / elapsed)
            for c in counters {
                guard let prev = lastPerInterface[c.name] else { continue }
                snapshot.interfaces.append((
                    name: c.name,
                    inPerSec: max(0, Double(c.bytesIn - prev.0) / elapsed),
                    outPerSec: max(0, Double(c.bytesOut - prev.1) / elapsed)))
            }
            snapshot.interfaces.sort { $0.inPerSec + $0.outPerSec > $1.inPerSec + $1.outPerSec }
        }

        lastTotalIn = totalIn
        lastTotalOut = totalOut
        lastDate = now
        lastPerInterface = Dictionary(uniqueKeysWithValues: counters.map { ($0.name, ($0.bytesIn, $0.bytesOut)) })
        return snapshot
    }

    // MARK: sysctl

    struct InterfaceCounters {
        let name: String
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    /// 全部处于 UP 状态的非回环网卡(awdl 点对点链路除外)的累计字节数。
    /// 网卡名不在消息头里,而在跟在 if_msghdr2 后的 sockaddr_dl 中。
    static func interfaceCounters() -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buffer, &size, nil, 0) == 0 else { return [] }

        var result: [InterfaceCounters] = []
        buffer.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            var cursor = base
            let end = base + size
            while cursor < end {
                let message = cursor.withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }
                let length = Int(message.ifm_msglen)
                guard length > 0 else { break }

                if message.ifm_type == u_char(RTM_IFINFO2) {
                    let flags = message.ifm_flags
                    let up = flags & IFF_UP != 0
                    let loopback = flags & IFF_LOOPBACK != 0
                    let name = interfaceName(in: cursor, messageLength: length)

                    if up && !loopback && !name.isEmpty && name != "awdl0" {
                        result.append(InterfaceCounters(name: name,
                                                        bytesIn: message.ifm_data.ifi_ibytes,
                                                        bytesOut: message.ifm_data.ifi_obytes))
                    }
                }
                cursor += length
            }
        }
        return result
    }

    /// 在 RTM_IFINFO2 消息头之后的地址列表里找 sockaddr_dl,取其中的网卡名。
    private static func interfaceName(in messageStart: UnsafePointer<CChar>,
                                      messageLength: Int) -> String {
        var offset = MemoryLayout<if_msghdr2>.size
        while offset + MemoryLayout<sockaddr>.size <= messageLength {
            let sa = (messageStart + offset).withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee }
            guard Int(sa.sa_len) > 0 else { return "" }
            if sa.sa_family == sa_family_t(AF_LINK) {
                let sdl = (messageStart + offset).withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                let nameLength = min(Int(sdl.sdl_nlen), 32)
                guard nameLength > 0 else { return "" }
                let dataOffset = offset + 8      // offsetof(sockaddr_dl, sdl_data)
                return (messageStart + dataOffset).withMemoryRebound(to: UInt8.self, capacity: nameLength) {
                    String(bytes: UnsafeBufferPointer(start: $0, count: nameLength), encoding: .utf8) ?? ""
                }
            }
            offset += Int(sa.sa_len)
        }
        return ""
    }
}

// MARK: - 电池

/// IOPowerSources 公开接口,读取首块在场的电池。台式机返回 nil。
enum BatteryReader {
    static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSIsPresentKey] as? Bool ?? false
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Double(current) / Double(max) * 100 : 0
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let state = description[kIOPSPowerSourceStateKey] as? String ?? ""
            // 放电时读 Time to Empty,充电时读 Time to Full,单位分钟。
            // 接着电源又不充电时这两个值都无意义(如已充满),不显示。
            let timeMeaningful = charging || !(state == (kIOPSACPowerValue as String))
            let minutesRaw = charging
                ? description[kIOPSTimeToFullChargeKey] as? Int
                : description[kIOPSTimeToEmptyKey] as? Int
            return BatteryInfo(percent: percent,
                               isCharging: charging,
                               onAC: state == (kIOPSACPowerValue as String),
                               timeRemainingMinutes: timeMeaningful && (minutesRaw ?? -1) >= 0 ? minutesRaw : nil)
        }
        return nil
    }
}
