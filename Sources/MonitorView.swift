import SwiftUI
import Charts
import Darwin

enum MonitorTab: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    case network = "网络"
    case disk = "磁盘"
    case io = "I/O"
    case battery = "电池"
    case glm = "智谱"
    case java = "Java"
    case processes = "进程"
    var id: String { rawValue }

    /// 窗口标签页与贴边卡片保持一致——没有电池的机器不显示电池页,
    /// 没配 API Key 不显示智谱页。
    static var activeTabs: [MonitorTab] {
        var list: [MonitorTab] = [.cpu, .memory, .network, .disk]
        if EdgeDockCards.cards.contains(.io) { list.append(.io) }
        if EdgeDockCards.cards.contains(.battery) { list.append(.battery) }
        if EdgeDockCards.cards.contains(.glm) { list.append(.glm) }
        if EdgeDockCards.cards.contains(.java) { list.append(.java) }
        list.append(.processes)
        return list
    }
}

// MARK: - 主视图

struct MonitorView: View {
    @ObservedObject var store: MonitorStore

    @State private var tab: MonitorTab = .cpu
    @State private var query = ""
    @State private var onlyMine = false
    @State private var selectedPID: Int32?
    @State private var sortOrder = [KeyPathComparator(\ProcInfo.cpuPercent, order: .reverse)]
    @State private var confirmTarget: ProcInfo?
    @State private var killErrorText: String?

    private var filtered: [ProcInfo] {
        var rows = ProcFilter.apply(store.processes, query: query, onlyMine: onlyMine, sortOrder: sortOrder)
        if tab == .java { rows = rows.filter(\.isJava) }
        return rows
    }

    private var selected: ProcInfo? {
        store.processes.first { $0.id == selectedPID }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            chartSection
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            processTable
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: tab) { _, new in
            switch new {
            case .cpu:
                sortOrder = [KeyPathComparator(\.cpuPercent, order: .reverse)]
            case .memory:
                sortOrder = [KeyPathComparator(\.memoryBytes, order: .reverse)]
            case .java:
                sortOrder = [KeyPathComparator(\.cpuPercent, order: .reverse)]
            case .network, .battery, .disk, .io, .glm, .processes:
                break
            }
        }
        .alert("强制退出进程", isPresented: Binding(
            get: { confirmTarget != nil },
            set: { if !$0 { confirmTarget = nil } }
        )) {
            Button("强制退出", role: .destructive) {
                if let target = confirmTarget { doKill(target) }
                confirmTarget = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要强制退出“\(confirmTarget?.name ?? "")”(PID \(confirmTarget?.pid ?? 0))吗?该进程未保存的数据将丢失。")
        }
        .alert("无法退出进程", isPresented: Binding(
            get: { killErrorText != nil },
            set: { if !$0 { killErrorText = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(killErrorText ?? "")
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("标签页", selection: $tab) {
                ForEach(MonitorTab.activeTabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .labelsHidden()

            Toggle("仅我的进程", isOn: $onlyMine)
                .toggleStyle(.checkbox)

            Picker("刷新间隔", selection: $store.interval) {
                Text("1 秒").tag(TimeInterval(1))
                Text("2 秒").tag(TimeInterval(2))
                Text("5 秒").tag(TimeInterval(5))
            }
            .pickerStyle(.menu)
            .frame(width: 86)
            .labelsHidden()
            .help("刷新间隔")

            Spacer()

            TextField("搜索进程 / PID / 用户", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Button {
                if let target = selected { confirmTarget = target }
            } label: {
                Label("强制退出", systemImage: "xmark.octagon.fill")
            }
            .disabled(selected == nil)
            .help("结束选中的进程")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 曲线区

    @ViewBuilder
    private var chartSection: some View {
        if tab == .cpu {
            VStack(alignment: .leading, spacing: 4) {
                Text(cpuHeadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let peak = store.dailyPeak {
                    Text(peak.sentence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                CPUChart(history: store.cpuHistory)
            }
        } else if tab == .network {
            VStack(alignment: .leading, spacing: 4) {
                Text("网络 — ↓ \(store.net.inPerSec.speedText) · ↑ \(store.net.outPerSec.speedText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                NetworkChart(down: store.netDownHistory, up: store.netUpHistory)
            }
        } else if tab == .disk, let boot = store.volumes.first {
            VStack(alignment: .leading, spacing: 4) {
                Text("磁盘 — \(boot.name) 已用 \(boot.usedBytes.memoryText) / \(boot.totalBytes.memoryText),剩余 \(boot.freeBytes.memoryText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VolumeGauge(volume: boot)
                    .padding(.top, 14)
            }
        } else if tab == .io {
            VStack(alignment: .leading, spacing: 4) {
                Text("磁盘 I/O — 读 ↓\(store.diskIO.readBytesPerSec.speedText) · 写 ↑\(store.diskIO.writeBytesPerSec.speedText) · IOPS \(Int(store.diskIO.readOpsPerSec + store.diskIO.writeOpsPerSec))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                NetworkChart(down: store.ioReadHistory, up: store.ioWriteHistory, tint: .blue, upTint: .orange)
                    .padding(.top, 6)
            }
        } else if tab == .java {
            VStack(alignment: .leading, spacing: 4) {
                Text(javaSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.processes.contains(where: \.isJava) {
                    Text("下方进程表只显示 JVM 进程,可排序、搜索与强制退出。堆内存与 GC 等 JVM 内部数据需要 attach,不在监控范围。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if tab == .battery, let battery = store.battery {
            VStack(alignment: .leading, spacing: 4) {
                Text("电池 — \(Int(battery.percent.rounded())) % · \(battery.isCharging ? "充电中" : (battery.onAC ? "已接电源" : "使用电池"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                BatteryGauge(battery: battery)
                    .padding(.top, 14)
            }
        } else if tab == .glm {
            VStack(alignment: .leading, spacing: 4) {
                if let fiveHour = store.glmPlan?.fiveHour {
                    Text("智谱 GLM 编码套餐 — 每 5 小时窗口剩 \(Int(fiveHour.remainingPercent.rounded()))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("智谱 GLM 编码套餐")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                GLMPlanContent(status: store.glmPlan)
                    .padding(.top, 10)
                    .padding(.horizontal, 2)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("内存 — 已用 \(store.system.memoryUsedBytes.memoryText) / \(store.system.memoryTotalBytes.memoryText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                MemoryChart(history: store.memHistory,
                            totalBytes: store.system.memoryTotalBytes)
            }
        }
    }

    private var cpuHeadline: String {
        var text = "系统 CPU 使用率 — 当前 \(store.system.cpuPercent.percentText) · \(store.system.coreCount) 核"
        if let name = store.digest.dominantName {
            text += " · 最忙 \(name) \(Int(store.digest.dominantCPU.rounded()))%"
        }
        return text
    }

    private var javaSummary: String {
        let jvms = store.processes.filter(\.isJava)
        guard !jvms.isEmpty else { return "Java — 没有正在运行的 JVM 进程" }
        let memory = jvms.reduce(UInt64(0)) { $0 + $1.memoryBytes }.memoryText
        let cpu = jvms.reduce(0.0) { $0 + $1.cpuPercent }
        return "Java — \(jvms.count) 个 JVM · 合计内存 \(memory) · 合计 CPU \(cpu.percentText)"
    }

    // MARK: 进程表

    private var processTable: some View {
        Table(filtered, selection: $selectedPID, sortOrder: $sortOrder) {
            TableColumn("进程", value: \.displayName) { row in
                Text(row.isJava ? "☕ \(row.displayName)" : row.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("强制退出 \(row.name)", role: .destructive) {
                            confirmTarget = row
                        }
                    }
            }
            .width(min: 160, ideal: 260)

            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            TableColumn("用户", value: \.user) { row in
                Text(row.user)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            TableColumn("CPU", value: \.cpuPercent) { row in
                Text(row.cpuPercent.percentText)
                    .monospacedDigit()
                    .foregroundStyle(row.cpuPercent > 90 ? .red : (row.cpuPercent > 50 ? .orange : .primary))
            }

            TableColumn("内存", value: \.memoryBytes) { row in
                Text(row.memoryBytes.memoryText)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90)

            TableColumn("线程", value: \.threadCount) { row in
                Text(String(row.threadCount))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 14) {
            if tab == .cpu {
                Text("用户 \(store.system.cpuUserPercent.percentText)")
                Text("系统 \(store.system.cpuSystemPercent.percentText)")
                Text("空闲 \((100 - store.system.cpuPercent).percentText)")
                Text("负载 \(store.system.loadAverages.0.loadText) \(store.system.loadAverages.1.loadText) \(store.system.loadAverages.2.loadText)")
                Spacer()
                Text("已运行 \(store.system.uptimeSeconds.uptimeText)")
            } else if tab == .network {
                Text("本机 IP \(store.primaryLocalIP ?? "—")")
                Text(store.net.interfaces.prefix(4)
                    .map { "\($0.name) ↓\($0.inPerSec.speedText) ↑\($0.outPerSec.speedText)" }
                    .joined(separator: "  ·  "))
                Spacer()
                Text("网卡 \(store.net.interfaces.count) 块")
            } else if tab == .disk {
                Text(store.volumes
                    .map { "\($0.name) 剩 \($0.freeBytes.memoryText) / \($0.totalBytes.memoryText)" }
                    .joined(separator: "  ·  "))
                Spacer()
            } else if tab == .io {
                Text("读 \(store.diskIO.readBytesPerSec.speedText) · 写 \(store.diskIO.writeBytesPerSec.speedText)")
                Text("IOPS \(Int(store.diskIO.readOpsPerSec)) / \(Int(store.diskIO.writeOpsPerSec))")
                Spacer()
                Text("累计读 \(store.diskIO.totalReadBytes.memoryText) · 累计写 \(store.diskIO.totalWrittenBytes.memoryText)")
            } else if tab == .battery, let battery = store.battery {
                Text(battery.isCharging ? "充电中" : (battery.onAC ? "已接电源" : "使用电池"))
                if let minutes = battery.timeRemainingMinutes {
                    Text("剩余约 \(minutes / 60) 小时 \(minutes % 60) 分钟")
                }
                Spacer()
            } else if tab == .glm {
                if let status = store.glmPlan {
                    Text(status.windows
                        .map { "\($0.label) 剩 \(Int($0.remainingPercent.rounded()))%" }
                        .joined(separator: "  ·  "))
                    Spacer()
                    Text("更新于 \(status.fetchedAt.formatted(date: .omitted, time: .shortened))")
                } else {
                    Spacer()
                }
            } else if tab == .java {
                Text(javaSummary)
                Spacer()
            } else {
                Text("联动 \(store.system.memoryWiredBytes.memoryText)")
                Text("已压缩 \(store.system.memoryCompressedBytes.memoryText)")
                Text("可清理 \(store.system.memoryCachedBytes.memoryText)")
                Text("物理空闲 \(store.system.memoryFreeBytes.memoryText)")
                Spacer()
                Text("交换 \(store.system.swapUsedBytes.memoryText) / \(store.system.swapTotalBytes.memoryText)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    // MARK: 动作

    private func doKill(_ target: ProcInfo) {
        if store.forceQuit(pid: target.pid) { return }
        killErrorText = "无法结束 PID \(target.pid)(\(target.name)):\(String(cString: strerror(errno)))"
    }
}

// MARK: - 曲线(cpu/mem 两个面板与完整窗口共用)

struct CPUChart: View {
    let history: [Double]
    var tint: Color = .blue
    var ink: Color = .secondary

    var body: some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("时间", index),
                    y: .value("CPU", value)
                )
                .foregroundStyle(.linearGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("时间", index),
                    y: .value("CPU", value)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f%%", v)).font(.caption2).foregroundStyle(ink)
                    }
                }
            }
        }
    }
}

struct MemoryChart: View {
    let history: [Double]     // GiB
    let totalBytes: UInt64
    var tint: Color = .green
    var ink: Color = .secondary

    private var totalGiB: Double { Double(totalBytes) / 1_073_741_824 }

    var body: some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("时间", index),
                    y: .value("内存", value)
                )
                .foregroundStyle(.linearGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                ))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("时间", index),
                    y: .value("内存", value)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...max(totalGiB, 1))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f GB", v)).font(.caption2).foregroundStyle(ink)
                    }
                }
            }
        }
    }
}

struct NetworkChart: View {
    let down: [Double]     // bytes/s
    let up: [Double]
    var tint: Color = .green
    var upTint: Color = .blue
    var ink: Color = .secondary

    private var peak: Double {
        max(max(down.max() ?? 0, up.max() ?? 0), 1024)
    }

    var body: some View {
        Chart {
            ForEach(Array(down.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("时间", index),
                    y: .value("下载", value)
                )
                .foregroundStyle(tint.opacity(0.16))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("时间", index),
                    y: .value("下载", value)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
            ForEach(Array(up.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("时间", index),
                    y: .value("上传", value)
                )
                .foregroundStyle(upTint)
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...peak)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v.speedText).font(.caption2).foregroundStyle(ink)
                    }
                }
            }
        }
    }
}

// MARK: - 格式化

extension Double {
    var percentText: String { String(format: "%.1f %%", self) }
    var loadText: String { String(format: "%.2f", self) }
    /// 速率自适应单位:B/s → KB/s → MB/s。
    var speedText: String {
        if self >= 1_048_576 { return String(format: "%.1fMB/s", self / 1_048_576) }
        if self >= 1024 { return String(format: "%.1fKB/s", self / 1024) }
        return "\(Int(self))B/s"
    }
}

extension UInt64 {
    var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .memory)
    }
}

extension TimeInterval {
    var uptimeText: String {
        let total = Int(self)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }
}
