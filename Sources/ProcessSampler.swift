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
    /// node / python 的脚本文件名。没有可识别的脚本时为 nil。
    let scriptLabel: String?
    var id: Int32 { pid }

    /// 列表显示名:运行时进程用业务标签,否则全是无区分度的 "java" / "node"。
    var displayName: String {
        if isJava { return javaLabel ?? name }
        if let scriptLabel, !scriptLabel.isEmpty { return scriptLabel }
        return name
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
                return row.displayName.lowercased().contains(q)
                    || row.name.lowercased().contains(q)
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
    /// 可执行路径按 pid 缓存(进程活着时不变)。只在采样队列上访问。
    private var pathCache: [Int32: String] = [:]
    /// JVM / node / python 的业务标签。空字符串表示命令行已读过、没有可展示的名字。
    /// 只在采样队列上访问。
    private var runtimeLabels: [Int32: String] = [:]
    /// CPU 卡上"当前最忙"的锁定名,避免两个进程来回抢卡面。
    private var latchedDominant: String?

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
            let path = self.path(for: pid)
            let runtime = runtimeLabel(pid: pid, path: path)

            result.append(ProcInfo(
                pid: pid,
                name: Self.displayName(path: path, comm: Self.commName(kp), pid: pid),
                path: path,
                user: Self.userName(uid),
                cpuPercent: cpu,
                memoryBytes: info.ptinfo.pti_resident_size,
                threadCount: Int(info.ptinfo.pti_threadnum),
                isCurrentUser: uid == myUID,
                isJava: runtime.isJava,
                javaLabel: runtime.javaLabel,
                scriptLabel: runtime.scriptLabel
            ))
        }

        lastCPUSeconds = next
        lastDate = now
        // 清掉已退出进程的缓存。
        pathCache = pathCache.filter { next[$0.key] != nil }
        runtimeLabels = runtimeLabels.filter { next[$0.key] != nil }
        return ProcessSample(date: now, processes: result)
    }

    /// 从一份进程表里抽出卡片要用的摘要。有锁定状态,只在采样队列上调用。
    func digest(of processes: [ProcInfo]) -> ProcessDigest {
        var digest = ProcessDigest(count: processes.count)
        var ranked: [ProcInfo] = []
        ranked.reserveCapacity(processes.count)
        for process in processes {
            if process.isJava {
                digest.javaCount += 1
                digest.javaMemoryBytes += process.memoryBytes
                digest.javaCPU += process.cpuPercent
            }
            if ProcessDigest.noiseNames.contains(process.name) { continue }
            ranked.append(process)
        }
        ranked.sort { $0.cpuPercent > $1.cpuPercent }

        let top = ranked.first
        let second = ranked.dropFirst().first?.cpuPercent ?? 0
        if let top, top.cpuPercent > 0 {
            digest.busiestName = top.displayName
        }

        let chosen: ProcInfo?
        if let latched = latchedDominant,
           let current = ranked.first(where: { $0.displayName == latched }),
           current.cpuPercent >= 50,
           (top == nil || current.displayName == top?.displayName
            || current.cpuPercent >= (top?.cpuPercent ?? 0) * 0.75) {
            chosen = current
        } else if let top, top.cpuPercent >= 50, top.cpuPercent >= max(second, 0.1) * 1.8 {
            chosen = top
        } else {
            chosen = nil
        }
        latchedDominant = chosen?.displayName
        if let chosen {
            digest.dominantName = ProcessDigest.cardToken(chosen.displayName)
            digest.dominantCPU = chosen.cpuPercent
        }
        return digest
    }

    /// 路径进程生命周期内不变。读失败不缓存,下一拍再试。
    private func path(for pid: Int32) -> String? {
        if let cached = pathCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, 4096) > 0 else { return nil }
        let value = String(cString: buffer)
        guard !value.isEmpty else { return nil }
        pathCache[pid] = value
        return value
    }

    /// JVM 看路径末段是不是 java;node / python 再从命令行摘脚本名。
    /// 命令行读成功后才缓存(包括"没有可展示名字"),读失败下一拍再试。
    private func runtimeLabel(pid: Int32, path: String?) -> (isJava: Bool, javaLabel: String?, scriptLabel: String?) {
        let base = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let isJava = base == "java"
        let isScript = Self.isScriptRuntime(base)
        guard isJava || isScript else { return (false, nil, nil) }

        let cached = runtimeLabels[pid]
        if let cached {
            let label = cached.isEmpty ? nil : cached
            return isJava ? (true, label, nil) : (false, nil, label)
        }
        guard let argv = Self.commandLine(pid: pid) else { return (isJava, nil, nil) }
        let label = isJava ? Self.javaLabel(argv) : Self.scriptLabel(argv)
        runtimeLabels[pid] = label ?? ""
        return isJava ? (true, label, nil) : (false, nil, label)
    }

    private static func isScriptRuntime(_ base: String) -> Bool {
        switch base {
        case "node", "nodejs", "python", "Python": return true
        default: return base.hasPrefix("python3")
        }
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

    /// node / python:第一个看起来像脚本的参数,取文件名。
    static func scriptLabel(_ argv: [String]) -> String? {
        for arg in argv.dropFirst() where !arg.hasPrefix("-") {
            let base = URL(fileURLWithPath: arg).lastPathComponent
            if base.hasSuffix(".js") || base.hasSuffix(".mjs") || base.hasSuffix(".cjs")
                || base.hasSuffix(".ts") || base.hasSuffix(".py") {
                return base
            }
        }
        return nil
    }
}
