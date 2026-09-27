import Foundation
import IOKit

// MARK: - 磁盘 I/O

/// 一次磁盘 I/O 采样的结果:全盘读写速率 + IOPS + 开机以来累计字节。
struct DiskIOSnapshot: Equatable {
    var readBytesPerSec: Double = 0
    var writeBytesPerSec: Double = 0
    var readOpsPerSec: Double = 0
    var writeOpsPerSec: Double = 0
    var totalReadBytes: UInt64 = 0
    var totalWrittenBytes: UInt64 = 0

    var totalBytesPerSec: Double { readBytesPerSec + writeBytesPerSec }
}

/// 从 IOKit 注册表的 IOBlockStorageDriver 统计属性读全盘读写字节数与
/// 操作次数(与 iostat 同源),相邻两次采样求差得出速率与 IOPS。
/// 有差分状态,只能在 MonitorStore 的串行队列上调用。
final class DiskIOSampler {
    private var lastRead: UInt64 = 0
    private var lastWritten: UInt64 = 0
    private var lastReadOps: UInt64 = 0
    private var lastWriteOps: UInt64 = 0
    private var lastDate: Date?

    func sample(now: Date = Date()) -> DiskIOSnapshot {
        var snapshot = DiskIOSnapshot()
        let totals = Self.diskTotals() ?? (0, 0, 0, 0)
        snapshot.totalReadBytes = totals.read
        snapshot.totalWrittenBytes = totals.written

        let elapsed = lastDate.map { now.timeIntervalSince($0) } ?? 0
        if elapsed > 0.05 {
            // 磁盘计数回退时按 0 计。回绕减法得到的是接近 UInt64.max 的值,
            // max(0, ...) 钳不住,会把这一拍画成巨大尖峰。
            snapshot.readBytesPerSec = Double(Self.counterDelta(totals.read, lastRead)) / elapsed
            snapshot.writeBytesPerSec = Double(Self.counterDelta(totals.written, lastWritten)) / elapsed
            snapshot.readOpsPerSec = Double(Self.counterDelta(totals.readOps, lastReadOps)) / elapsed
            snapshot.writeOpsPerSec = Double(Self.counterDelta(totals.writeOps, lastWriteOps)) / elapsed
        }

        lastRead = totals.read
        lastWritten = totals.written
        lastReadOps = totals.readOps
        lastWriteOps = totals.writeOps
        lastDate = now
        return snapshot
    }

    /// 计数回退时差值为 0,避免回绕后速率失真。
    private static func counterDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    // MARK: IOKit

    typealias Totals = (read: UInt64, written: UInt64, readOps: UInt64, writeOps: UInt64)

    /// 汇总所有块存储驱动(Intel NVMe/AHCI、外接盘等)的累计统计。
    /// Statistics 字典的键名带空格括号,取自 iostat 的读法:
    /// "Bytes (Read)" / "Bytes (Write)" / "Operations (Read)" / "Operations (Write)"。
    static func diskTotals() -> Totals? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var totals = Totals(read: 0, written: 0, readOps: 0, writeOps: 0)
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any]
            else { continue }
            found = true
            totals.read += number(stats["Bytes (Read)"])
            totals.written += number(stats["Bytes (Write)"])
            totals.readOps += number(stats["Operations (Read)"])
            totals.writeOps += number(stats["Operations (Write)"])
        }
        return found ? totals : nil
    }

    /// CFNumber → UInt64(计数器都是 64 位无符号)。
    private static func number(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}
