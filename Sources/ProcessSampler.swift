import Foundation
import Darwin

/// 表格中的一行进程。CPU 百分比与活动监视器同口径:100% = 单核满载,多核可超过 100。
struct ProcInfo: Identifiable {
    let pid: Int32
    let name: String
    let path: String?
    let user: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let threadCount: Int
    let isCurrentUser: Bool
    /// 可执行路径以 /bin/java 结尾的 JVM 进程。
    let isJava: Bool
    /// JVM 的业务标签:从命令行提取的 -jar 包名或主类名,如 "foo.jar"、"GradleDaemon"。
    let javaLabel: String?
    var id: Int32 { pid }

    /// 列表显示名:Java 进程优先用业务标签,否则全是无区分度的 "java"。
    var displayName: String {
        isJava ? (javaLabel ?? name) : name
    }
}

struct ProcessSample {
    let date: Date
    let processes: [ProcInfo]
}

/// 进程表的共享过滤/排序口径:完整窗口与贴边进程面板保持一致。
enum ProcFilter {
    static func apply(_ processes: [ProcInfo], query: String, onlyMine: Bool,
                      sortOrder: [KeyPathComparator<ProcInfo>]) -> [ProcInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return processes
            .filter { row in
                if onlyMine && !row.isCurrentUser { return false }
                guard !q.isEmpty else { return true }
                return row.name.lowercased().contains(q)
                    || row.user.lowercased().contains(q)
                    || String(row.pid).contains(q)
            }
            .sorted(using: sortOrder)
    }
}

/// 每个采样周期枚举全部进程:sysctl 拿列表,libproc 拿每个进程的
/// 累计 CPU 时间与驻留内存,相邻两次采样求差值得出 CPU%。
/// 只在采样串行队列上使用,自身无需加锁。
final class ProcessSampler {
    private var lastCPUSeconds: [Int32: Double] = [:]
    private var lastDate: Date?
    private static var uidCache: [UInt32: String] = [:]
    /// JVM 业务标签缓存(参数进程生命周期内不变),只在采样队列上访问。
    private var javaLabels: [Int32: String] = [:]

    /// pti_total_user / pti_total_system 是 mach 时基 tick(Apple Silicon 上
    /// 24 MHz,1 tick ≠ 1µs),必须用 mach_timebase_info 换算成秒。
    private static let tickToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    func sample(now: Date = Date()) -> ProcessSample {
        let elapsed = lastDate.map { now.timeIntervalSince($0) } ?? 0
        let kinfo = Self.processList()
        var result: [ProcInfo] = []
        result.reserveCapacity(kinfo.count)
        var next: [Int32: Double] = [:]
        next.reserveCapacity(kinfo.count)
        let myUID = getuid()

        for kp in kinfo {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }              // 0 = kernel_task,读不到 taskinfo
            if kp.kp_proc.p_stat == 5 { continue }       // 5 = SZOMB 僵尸进程

            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { continue }

            let totalTicks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
            let seconds = Double(totalTicks) * Self.tickToSeconds
            next[pid] = seconds

            var cpu = 0.0
            if elapsed > 0.05, let prev = lastCPUSeconds[pid] {
                cpu = max(0, (seconds - prev) / elapsed * 100)
            }

            let uid = kp.kp_eproc.e_ucred.cr_uid
            var path: String?
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, 4096) > 0 {
                path = String(cString: buffer)
            }

            // JVM 识别:可执行路径以 /bin/java 结尾(java、Gradle/Kotlin daemon、
            // IDE 内置 JBR 全是这个特征)。标签从命令行参数提取,按 pid 缓存。
            let isJava = path?.hasSuffix("/java") ?? false
            var javaLabel: String?
            if isJava {
                if let cached = javaLabels[pid] {
                    javaLabel = cached
                } else if let argv = Self.commandLine(pid: pid), let label = Self.javaLabel(argv) {
                    javaLabel = label
                    javaLabels[pid] = label
                }
            }

            result.append(ProcInfo(
                pid: pid,
                name: Self.displayName(path: path, comm: Self.commName(kp), pid: pid),
                path: path,
                user: Self.userName(uid),
                cpuPercent: cpu,
                memoryBytes: info.ptinfo.pti_resident_size,
                threadCount: Int(info.ptinfo.pti_threadnum),
                isCurrentUser: uid == myUID,
                isJava: isJava,
                javaLabel: javaLabel
            ))
        }

        lastCPUSeconds = next
        lastDate = now
        // 清掉已退出的 JVM 的标签缓存。
        javaLabels = javaLabels.filter { next[$0.key] != nil }
        return ProcessSample(date: now, processes: result)
    }

    // MARK: - Helpers

    private static func processList() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        guard capacity > 0 else { return [] }
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return count > 0 ? Array(buffer.prefix(count)) : []
    }

    /// p_comm 是定长 Int8 元组,截到首个 NUL 转字符串。
    private static func commName(_ kp: kinfo_proc) -> String {
        withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            var bytes: [UInt8] = []
            for byte in raw where byte != 0 { bytes.append(byte) }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }

    /// .app 包内取应用名(/Applications/Safari.app/… → Safari),其余取可执行文件名。
    private static func displayName(path: String?, comm: String, pid: Int32) -> String {
        if let path, !path.isEmpty {
            let parts = path.split(separator: "/").map(String.init)
            if let idx = parts.lastIndex(where: { $0.hasSuffix(".app") }) {
                return String(parts[idx].dropLast(4))
            }
            if let last = parts.last, !last.isEmpty { return last }
        }
        return comm.isEmpty ? "PID \(pid)" : comm
    }

    private static func userName(_ uid: UInt32) -> String {
        if let cached = uidCache[uid] { return cached }
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return "uid \(uid)" }
        let value = String(cString: name)
        uidCache[uid] = value
        return value
    }

    // MARK: - JVM 标签

    /// KERN_PROCARGS2 读完整命令行(与 ps 同源,公开接口)。
    /// 缓冲区布局:argc(int32)、可执行路径、对齐用的 NUL 填充、argv 字符串×argc、环境变量…。
    static func commandLine(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = Data(count: size)
        let result = buffer.withUnsafeMutableBytes {
            sysctl(&mib, 3, $0.baseAddress, &size, nil, 0)
        }
        guard result == 0, size >= 4 else { return nil }

        let argc = min(Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) }), 512)
        var offset = 4
        func readString() -> String {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            let value = String(decoding: buffer[start..<offset], as: UTF8.self)
            offset += 1
            return value
        }
        guard argc > 0 else { return nil }
        _ = readString()                        // 可执行路径
        while offset < size, buffer[offset] == 0 { offset += 1 }   // 跳过对齐填充
        var argv: [String] = []
        for _ in 0..<argc where offset < size {
            argv.append(readString())
        }
        return argv
    }

    /// 从 argv 提取 JVM 的业务标签:优先 `-jar` 的包名,其次主类名的末段
    /// (Gradle/Kotlin daemon 就是 "GradleDaemon" 这类)。识别不了返回 nil。
    static func javaLabel(_ argv: [String]) -> String? {
        let args = argv.dropFirst()
        if let i = args.firstIndex(of: "-jar"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1]).lastPathComponent
        }
        // 主类:不含路径分隔/冒号/jar 后缀、带包名点号的参数。
        // classpath 值(含 ":" 或 "/")、JVM 标志(以 "-" 开头)都落在识别条件之外。
        let classes = args.filter {
            !$0.hasPrefix("-") && !$0.hasSuffix(".jar") &&
            !$0.contains("/") && !$0.contains(":") && $0.contains(".")
        }
        if let cls = classes.first {
            return cls.split(separator: ".").last.map(String.init)
        }
        // 默认包里的裸主类(无点号)。
        return args.first { !$0.hasPrefix("-") }
    }
}
