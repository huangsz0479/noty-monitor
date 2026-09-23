import Foundation

// MARK: - 进程摘要

/// 卡片和提醒用的进程摘要。完整进程表只在有人看的时候才上主线程,
/// 贴边卡读的是这一小份。
struct ProcessDigest: Equatable {
    var count = 0
    var javaCount = 0
    var javaMemoryBytes: UInt64 = 0
    var javaCPU = 0.0
    /// 明显占住机器的那个进程(短名,给 CPU 卡用)。没有主导者时为 nil。
    var dominantName: String?
    var dominantCPU = 0.0
    /// 当前最忙的非系统进程,给"今天峰值"那句话用。
    var busiestName: String?

    /// 卡面竖排装不下长名字,超长就截到还能看的长度。
    static func cardToken(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 14 { return trimmed }
        return String(trimmed.prefix(12))
    }
}

/// 今天这台机器最忙的一刻。只留一句话,不存整段曲线。
struct DailyPeak: Equatable {
    var cpuPercent: Double
    var processName: String?
    var at: Date

    var sentence: String {
        let time = at.formatted(date: .omitted, time: .shortened)
        let cpu = cpuPercent.percentText
        if let processName, !processName.isEmpty {
            return "今天 \(time) CPU 到过 \(cpu)，当时是 \(processName)"
        }
        return "今天 \(time) CPU 到过 \(cpu)"
    }
}

// MARK: - 彩条深浅

/// 小圆点上每根彩条的强度,0...1,按 8 档量化,没跨档就不重绘。
struct DashLevels: Equatable {
    var cpu = 0.0
    var memory = 0.0
    var network = 0.0
    var disk = 0.0
    var io = 0.0
    var battery = 0.0
    var glm = 0.0
    var java = 0.0
    var processes = 0.75
    /// 便签不是用量,彩条保持常亮。
    var note = 0.8

    func level(for kind: DockPanelKind) -> Double {
        switch kind {
        case .cpu: return cpu
        case .memory: return memory
        case .network: return network
        case .disk: return disk
        case .io: return io
        case .battery: return battery
        case .glm: return glm
        case .java: return java
        case .processes: return processes
        case .note: return note
        }
    }

    /// 把 0...1 收成 8 档,避免速率每拍微变都让彩条重绘。
    static func bucket(_ value: Double) -> Double {
        (min(1, max(0, value)) * 8).rounded() / 8
    }

    /// 网速 / 磁盘吞吐没有自然上限:约 20 MB/s 视为满格,空闲接近 0。
    static func traffic(_ bytesPerSec: Double) -> Double {
        let mb = bytesPerSec / 1_048_576
        guard mb > 0 else { return 0 }
        return min(1, log10(1 + mb) / log10(1 + 20))
    }
}

// MARK: - 探出哪一张卡

/// 静止时要不要自己探出一张卡。带滞回,避免在阈值附近来回抽。
struct AttentionTracker {
    private var cpu = 0.0
    private var cpuHot = 0
    private var latched: DockPanelKind?

    /// 只在主采样落地时记一次 CPU,套餐回调不能再记,否则热计数会翻倍。
    mutating func noteCPU(_ value: Double) {
        cpu = value
        if value >= 85 {
            cpuHot += 1
        } else if value < 70 {
            cpuHot = 0
        }
    }

    mutating func resolve(battery: BatteryInfo?, glmRemaining: Double?,
                          enabled: Set<DockPanelKind>) -> DockPanelKind? {
        let cpuWanted = enabled.contains(.cpu) && cpuHot >= 3
        let cpuClear = cpu < 70 || !enabled.contains(.cpu)

        let batteryWanted = enabled.contains(.battery)
            && (battery.map { $0.percent <= 20 && !$0.isCharging && !$0.onAC } ?? false)
        let batteryClear = battery.map { $0.percent >= 30 || $0.isCharging || $0.onAC } ?? true

        let glmWanted = enabled.contains(.glm) && (glmRemaining.map { $0 <= 15 } ?? false)
        let glmClear = !enabled.contains(.glm) || glmRemaining == nil || (glmRemaining ?? 100) >= 25

        if let latched {
            let still: Bool
            switch latched {
            case .cpu: still = !cpuClear
            case .battery: still = !batteryClear
            case .glm: still = !glmClear
            default: still = false
            }
            if still { return latched }
            self.latched = nil
        }

        let next: DockPanelKind?
        if batteryWanted {
            next = .battery
        } else if glmWanted {
            next = .glm
        } else if cpuWanted {
            next = .cpu
        } else {
            next = nil
        }
        latched = next
        return next
    }
}
