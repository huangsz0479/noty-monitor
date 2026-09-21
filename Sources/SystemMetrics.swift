import Foundation
import Darwin

/// 一次系统级采样的结果(增量字段由 SystemSampler 计算后填入)。
struct SystemSnapshot {
    var cpuPercent = 0.0        // 全核聚合占用,0–100
    var cpuUserPercent = 0.0
    var cpuSystemPercent = 0.0
    var loadAverages: (Double, Double, Double) = (0, 0, 0)
    var coreCount = 0
    var memoryTotalBytes: UInt64 = 0
    var memoryUsedBytes: UInt64 = 0        // ≈ 活跃 + 联动 + 已压缩
    var memoryWiredBytes: UInt64 = 0
    var memoryCompressedBytes: UInt64 = 0
    var memoryCachedBytes: UInt64 = 0      // 非活跃 + 推测,可被回收
    var memoryFreeBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var uptimeSeconds: TimeInterval = 0
    var sampleDate = Date()
}

/// CPU 时间片计数。tick 单位为 1/100 秒;字段顺序按 CPU_STATE_* 的宏定义。
struct CPUTicks {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var idle: UInt64 = 0
    var nice: UInt64 = 0
    var total: UInt64 { user + system + idle + nice }
    var busy: UInt64 { user + system + nice }
}

/// 无状态的系统指标原始读取,全部走公开的 Mach/sysctl 接口。
enum SystemMetrics {
    static let pageSize: UInt64 = {
        var value: UInt64 = 4096
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.pagesize", &value, &size, nil, 0) != 0 { value = 4096 }
        return value
    }()

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0),     // CPU_STATE_USER
                        system: UInt64(info.cpu_ticks.1),   // CPU_STATE_SYSTEM
                        idle: UInt64(info.cpu_ticks.2),     // CPU_STATE_IDLE
                        nice: UInt64(info.cpu_ticks.3))     // CPU_STATE_NICE
    }

    static func snapshot(now: Date = Date()) -> SystemSnapshot {
        var snap = SystemSnapshot()
        snap.sampleDate = now
        snap.coreCount = ProcessInfo.processInfo.activeProcessorCount
        snap.memoryTotalBytes = ProcessInfo.processInfo.physicalMemory

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 {
            snap.loadAverages = (load[0], load[1], load[2])
        }

        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = pageSize
            let active = UInt64(info.active_count)
            let wired = UInt64(info.wire_count)
            let compressed = UInt64(info.compressor_page_count)
            snap.memoryUsedBytes = (active + wired + compressed) * page
            snap.memoryWiredBytes = wired * page
            snap.memoryCompressedBytes = compressed * page
            snap.memoryCachedBytes = (UInt64(info.inactive_count) + UInt64(info.speculative_count)) * page
            snap.memoryFreeBytes = UInt64(info.free_count) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            snap.swapUsedBytes = UInt64(swap.xsu_used)
            snap.swapTotalBytes = UInt64(swap.xsu_total)
        }

        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0, boot.tv_sec != 0 {
            snap.uptimeSeconds = max(0, now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))))
        }
        return snap
    }
}

/// 持有上一次的 tick,对两次采样求差值得出 CPU 占用。只在采样串行队列上使用。
final class SystemSampler {
    private var previous: (ticks: CPUTicks, date: Date)?

    func sample(now: Date = Date()) -> SystemSnapshot {
        var snap = SystemMetrics.snapshot(now: now)
        guard let ticks = SystemMetrics.cpuTicks() else { return snap }
        if let prev = previous {
            let elapsed = now.timeIntervalSince(prev.date)
            if elapsed > 0.05 {
                let dTotal = Int64(ticks.total) - Int64(prev.ticks.total)
                if dTotal > 0 {
                    let dBusy = Int64(ticks.busy) - Int64(prev.ticks.busy)
                    let dUser = Int64(ticks.user) - Int64(prev.ticks.user)
                    let dSystem = Int64(ticks.system) - Int64(prev.ticks.system)
                    snap.cpuPercent = clampPercent(dBusy, dTotal)
                    snap.cpuUserPercent = clampPercent(dUser, dTotal)
                    snap.cpuSystemPercent = clampPercent(dSystem, dTotal)
                }
            }
        }
        previous = (ticks, now)
        return snap
    }

    private func clampPercent(_ delta: Int64, _ total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(100, max(0, Double(delta) / Double(total) * 100))
    }
}
