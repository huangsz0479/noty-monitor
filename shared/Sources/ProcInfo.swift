import Foundation

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

/// 进程表的过滤/排序口径:完整窗口与贴边进程面板保持一致。
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

/// 从命令行参数里认出 JVM / node / python 的业务名。不读进程表。
enum RuntimeLabels {
    static func isScriptRuntime(_ base: String) -> Bool {
        switch base {
        case "node", "nodejs", "python", "Python": return true
        default: return base.hasPrefix("python3")
        }
    }

    /// 优先 `-jar` 的包名,其次主类名的末段
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
