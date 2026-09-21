import Foundation
import Combine
import Darwin

/// 定时采样并发布到 UI。采样在后台串行队列执行,结果经主队列回写
/// (@Published 属性全部在主线程更新)。
final class MonitorStore: ObservableObject {
    static let shared = MonitorStore()

    @Published private(set) var processes: [ProcInfo] = []
    @Published private(set) var system = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []   // 全核聚合 %
    @Published private(set) var memHistory: [Double] = []   // 已用 GiB
    @Published private(set) var net = NetSnapshot()
    @Published private(set) var netDownHistory: [Double] = []   // bytes/s
    @Published private(set) var netUpHistory: [Double] = []     // bytes/s
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var localIPs: [LocalIPReader.Address] = []
    /// 卡片高度实测完成后 bump,驱动贴边列重排。
    @Published var layoutTick = 0

    /// 主内网 IP:优先 en* 网卡的 IPv4。
    var primaryLocalIP: String? {
        localIPs.first { $0.ip.contains(".") }?.ip
    }

    @Published var interval: TimeInterval = 2.0 {
        didSet {
            guard started, oldValue != interval else { return }
            startTimer()
        }
    }

    private var started = false
    private let queue = DispatchQueue(label: "sysmon.sampler", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private let networkSampler = NetworkSampler()
    private let historyLimit = 150

    func start() {
        guard !started else { return }
        started = true
        startTimer()
    }

    /// ⌘R 手动刷新。
    func sampleNow() {
        queue.async { [weak self] in self?.performSample() }
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.performSample() }
        t.resume()
        timer = t
    }

    private func performSample() {
        let processSample = processSampler.sample()
        let systemSnapshot = systemSampler.sample(now: processSample.date)
        let netSnapshot = networkSampler.sample(now: processSample.date)
        let batteryInfo = BatteryReader.read()
        let volumeList = DiskReader.volumes()
        let ipList = LocalIPReader.addresses()
        DispatchQueue.main.async { [weak self] in
            self?.apply(processSample: processSample, system: systemSnapshot,
                        net: netSnapshot, battery: batteryInfo,
                        volumes: volumeList, localIPs: ipList)
        }
    }

    private func apply(processSample ps: ProcessSample, system snapshot: SystemSnapshot,
                       net netSnapshot: NetSnapshot, battery batteryInfo: BatteryInfo?,
                       volumes volumeList: [VolumeInfo], localIPs ipList: [LocalIPReader.Address]) {
        processes = ps.processes
        system = snapshot
        net = netSnapshot
        battery = batteryInfo
        volumes = volumeList
        localIPs = ipList

        cpuHistory.append(snapshot.cpuPercent)
        if cpuHistory.count > historyLimit { cpuHistory.removeFirst(cpuHistory.count - historyLimit) }

        memHistory.append(Double(snapshot.memoryUsedBytes) / 1_073_741_824)
        if memHistory.count > historyLimit { memHistory.removeFirst(memHistory.count - historyLimit) }

        netDownHistory.append(netSnapshot.inPerSec)
        if netDownHistory.count > historyLimit { netDownHistory.removeFirst(netDownHistory.count - historyLimit) }

        netUpHistory.append(netSnapshot.outPerSec)
        if netUpHistory.count > historyLimit { netUpHistory.removeFirst(netUpHistory.count - historyLimit) }
    }

    /// 强制退出(SIGKILL)。其他用户的进程会失败,由调用方展示错误。
    @discardableResult
    func forceQuit(pid: Int32) -> Bool {
        kill(pid, SIGKILL) == 0
    }
}
