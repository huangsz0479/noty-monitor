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
    @Published private(set) var diskIO = DiskIOSnapshot()
    @Published private(set) var ioReadHistory: [Double] = []    // bytes/s
    @Published private(set) var ioWriteHistory: [Double] = []   // bytes/s
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var localIPs: [LocalIPReader.Address] = []
    /// 智谱 GLM 编码套餐余量(未设置 API Key 时为 nil)。
    @Published private(set) var glmPlan: GLMPlanStatus?
    /// 卡片高度实测完成后 bump,驱动贴边列重排。
    @Published var layoutTick = 0

    /// 主内网 IP:优先 en* 网卡的 IPv4。
    var primaryLocalIP: String? {
        localIPs.first { $0.ip.contains(".") }?.ip
    }

    @Published var interval: TimeInterval = {
        let stored = UserDefaults.standard.object(forKey: "refreshInterval") as? TimeInterval
        return [1.0, 2.0, 5.0].contains(stored) ? stored! : 2.0
    }() {
        didSet {
            guard oldValue != interval else { return }
            UserDefaults.standard.set(interval, forKey: "refreshInterval")
            guard started else { return }
            startTimer()
        }
    }

    private var started = false
    private let queue = DispatchQueue(label: "sysmon.sampler", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private let networkSampler = NetworkSampler()
    private let diskIOSampler = DiskIOSampler()
    private let historyLimit = 150
    /// 套餐余量变化很慢,独立 60s 轮询,不走主采样循环(网络请求不能阻塞
    /// 串行采样队列)。
    private let glmQueue = DispatchQueue(label: "sysmon.glm", qos: .utility)
    private var glmTimer: DispatchSourceTimer?
    private var glmBag = Set<AnyCancellable>()
    /// 采样周期计数,只在采样队列上访问。
    private var tick = 0
    /// 低频数据的最近一次读数(电池/卷/IP 变化很慢,不必每个周期都读),
    /// 同样只在采样队列上访问。
    private var cachedBattery: BatteryInfo?
    private var cachedVolumes: [VolumeInfo] = []
    private var cachedIPs: [LocalIPReader.Address] = []

    func start() {
        guard !started else { return }
        started = true
        startTimer()
        startGLMPolling()
    }

    /// ⌘R 手动刷新。
    func sampleNow() {
        queue.async { [weak self] in self?.performSample() }
        fetchGLMPlan()
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
        let ioSnapshot = diskIOSampler.sample(now: processSample.date)
        // 首个周期全量读;之后电池约 10s、卷与 IP 约 30s 才重读一次(按 2s 间隔计)。
        if tick % 5 == 0 { cachedBattery = BatteryReader.read() }
        if tick % 15 == 0 {
            cachedVolumes = DiskReader.volumes()
            cachedIPs = LocalIPReader.addresses()
        }
        tick &+= 1
        let batteryInfo = cachedBattery
        let volumeList = cachedVolumes
        let ipList = cachedIPs
        DispatchQueue.main.async { [weak self] in
            self?.apply(processSample: processSample, system: systemSnapshot,
                        net: netSnapshot, io: ioSnapshot, battery: batteryInfo,
                        volumes: volumeList, localIPs: ipList)
        }
    }

    private func apply(processSample ps: ProcessSample, system snapshot: SystemSnapshot,
                       net netSnapshot: NetSnapshot, io ioSnapshot: DiskIOSnapshot,
                       battery batteryInfo: BatteryInfo?,
                       volumes volumeList: [VolumeInfo], localIPs ipList: [LocalIPReader.Address]) {
        processes = ps.processes
        system = snapshot
        net = netSnapshot
        diskIO = ioSnapshot
        // 低频数据不变时不重写 @Published,避免无意义的界面重绘。
        if battery != batteryInfo { battery = batteryInfo }
        if volumes != volumeList { volumes = volumeList }
        if localIPs != ipList { localIPs = ipList }

        cpuHistory.append(snapshot.cpuPercent)
        if cpuHistory.count > historyLimit { cpuHistory.removeFirst(cpuHistory.count - historyLimit) }

        memHistory.append(Double(snapshot.memoryUsedBytes) / 1_073_741_824)
        if memHistory.count > historyLimit { memHistory.removeFirst(memHistory.count - historyLimit) }

        netDownHistory.append(netSnapshot.inPerSec)
        if netDownHistory.count > historyLimit { netDownHistory.removeFirst(netDownHistory.count - historyLimit) }

        netUpHistory.append(netSnapshot.outPerSec)
        if netUpHistory.count > historyLimit { netUpHistory.removeFirst(netUpHistory.count - historyLimit) }

        ioReadHistory.append(ioSnapshot.readBytesPerSec)
        if ioReadHistory.count > historyLimit { ioReadHistory.removeFirst(ioReadHistory.count - historyLimit) }

        ioWriteHistory.append(ioSnapshot.writeBytesPerSec)
        if ioWriteHistory.count > historyLimit { ioWriteHistory.removeFirst(ioWriteHistory.count - historyLimit) }
    }

    /// 强制退出(SIGKILL)。其他用户的进程会失败,由调用方展示错误。
    @discardableResult
    func forceQuit(pid: Int32) -> Bool {
        kill(pid, SIGKILL) == 0
    }

    // MARK: 智谱套餐余量

    private func startGLMPolling() {
        glmTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: glmQueue)
        t.schedule(deadline: .now(), repeating: 60.0)
        t.setEventHandler { [weak self] in self?.fetchGLMPlan() }
        t.resume()
        glmTimer = t
        // 设置里改了 API Key 后马上重查(逐字输入会连发,做 0.8s 防抖)。
        CardSettings.shared.$glmApiKey
            .removeDuplicates()
            .debounce(for: .milliseconds(800), scheduler: glmQueue)
            .sink { [weak self] _ in self?.fetchGLMPlan() }
            .store(in: &glmBag)
    }

    /// 查一次套餐余量,定时器与手动刷新共用。结果在主队列落地,且只在
    /// 数据真的变化时才写 @Published(fetchedAt 不参与相等判断)。
    func fetchGLMPlan() {
        let key = CardSettings.shared.glmApiKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if glmPlan != nil { DispatchQueue.main.async { self.glmPlan = nil } }
            return
        }
        GLMPlanReader.fetch(apiKey: key) { [weak self] status in
            guard let self, status != self.glmPlan else { return }
            self.glmPlan = status
        }
    }
}
