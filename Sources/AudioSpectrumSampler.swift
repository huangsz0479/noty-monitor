import Foundation
import CoreAudio
import Accelerate
import AVFoundation
import os

// MARK: - 声音律动(系统输出频谱)

/// 左下角频谱条。只有条的高度变了才发布。
final class PulseFrame: ObservableObject {
    @Published private(set) var bands: [Double] = Array(repeating: 0, count: PulseModel.bandCount)

    func update(_ next: [Double]) {
        guard next != bands else { return }
        bands = next
    }
}

/// 律动的实时数据。独立于 MonitorStore:频谱条和诊断分开,
/// 没声音时不把左下角按 30Hz 重画。
final class PulseModel: ObservableObject {
    static let shared = PulseModel()
    static let bandCount = 24

    /// 频谱条。和诊断信息分开,设置页刷新诊断时不会带动左下角重画。
    let frame = PulseFrame()
    /// 是否正在采集。
    @Published var running = false
    /// 授权/设备错误等需要展示的状态。
    @Published var statusMessage: String?
    /// 逐阶段的装配/运行诊断,给设置页的「律动」页实时展示。
    @Published var diagnostics = ""
}

/// 截取系统混音后的输出音频(CoreAudio Process Tap,macOS 14.4+),用 vDSP
/// 做 FFT 得到 24 个对数频段。只读波形做律动,不录音、不落盘。
///
/// 权限:截取系统播放走「系统音频录制」(Info.plist 的
/// NSAudioCaptureUsageDescription)。只允许「麦克风」时缓冲全是 0。
///
/// 抽头 muteBehavior 保持 unmuted,只旁路读取,不把播放静音。
/// 没人播放时不拆抽头:拆掉再挂,音频服务有时会把下一次播放的通路弄断。
/// 输出设备或采样率变了,以及正在播放却收不到声音时,才重挂。
final class AudioSpectrumSampler {
    // CoreAudio 状态
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "sysmon.pulse.io", qos: .userInitiated)
    /// 装配/拆除不走 IO 队列:在 IO 队列里 AudioDeviceStop 会和回调互相等死。
    private let setupQueue = DispatchQueue(label: "sysmon.pulse.setup")
    private var sampleRate: Double = 48000
    /// 聚合设备输入的总声道数(硬件输入在前,抽头接在后面)。交错格式下也是帧步长。
    private var channels = 2
    private var interleaved = false
    /// 抽头自己的声道数,以及它在聚合输入里的起始下标。
    private var tapChannelCount = 2
    private var tapChannelOffset = 0
    /// 每个输入缓冲的峰值,用来发现"抽头不在我们以为的那几路"。
    private var bufferPeaks = [Float](repeating: 0, count: 16)

    // 采样环形缓冲(IO 实时线程写,分析线程读)。
    // 实时线程只用 trylock:等锁会堵住系统混音,声音就放不出来。
    private let gate = OSAllocatedUnfairLock()
    private var ring = [Float](repeating: 0, count: 1 << 15)
    private var ringMask = (1 << 15) - 1
    private var ringWrite = 0
    private var ringFilled = 0

    // FFT(Accelerate/vDSP,分析线程专用)
    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var fftReal = [Float]()
    private var fftImag = [Float]()
    private var magnitudes = [Float]()
    private var display = [Double](repeating: 0, count: PulseModel.bandCount)
    private var peaks = [Double](repeating: 0, count: PulseModel.bandCount)
    private var displayLevel = 0.0
    private var bandRanges: [Range<Int>] = []

    private let analysisQueue = DispatchQueue(label: "sysmon.pulse.analysis", qos: .utility)
    private var analysisTimer: DispatchSourceTimer?
    private var shouldRun = false
    /// 采样期间禁止 App Nap(否则后台队列与音频被节流,律动会静默死掉)。
    private var activityToken: NSObjectProtocol?
    /// 上次收到非零波形的时间。正在播放却一直是 0,说明抽头挂死了。
    private var lastNonZeroAt = Date()
    private var lastRecreateAt = Date.distantPast
    private var healCount = 0
    /// 因「有回调但全是静音」已经重挂的次数。只在 setupQueue 上改。
    /// 输出设备经常被浏览器占着却没有可听内容,不能因此无限拆建抽头。
    private var deafHeals = 0
    /// 分析线程上的记号:静音预算已经被花过,听到声音或停止播放时清一次。
    private var deafHealsClear = true
    /// 输出设备从「没人播放」变成「正在播放」的时刻。没人播放时不重挂。
    private var sawOutputRunning = false
    private var outputRunningSince = Date.distantPast
    /// IO 回调刚进来就记下的时刻。不拿 gate,这样丢掉缓冲时也知道回调还活着。
    private let lastIOTick = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var systemOutputListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateDeviceID: AudioDeviceID = 0
    private var watchedRate: Double = 0
    private var watchedOutputID: AudioDeviceID = 0
    private var watchedSystemOutputID: AudioDeviceID = 0
    private var rebuildWork: DispatchWorkItem?
    /// IO 回调计数(诊断用,锁内读写)。
    private var ioCallbacks = 0
    private var totalFrames = 0
    private var lastDiagAt = Date.distantPast

    private func updateDiag(_ text: String) {
        DispatchQueue.main.async { PulseModel.shared.diagnostics = text }
    }

    // 'tfmt':kAudioTapPropertyFormat 是匿名 C 枚举成员,Swift 导不进来。
    private let tapFormatSelector = AudioObjectPropertySelector(0x74_66_6D_74)

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        // 采样期间禁止 App Nap,否则后台队列被节流、律动会静默死掉。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "声音律动采集")
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            setupQueue.async { [weak self] in
                guard let self else { return }
                self.installOutputListeners()
                self.setupTap()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.setupQueue.async {
                    guard let self, self.shouldRun else { return }
                    if granted {
                        self.installOutputListeners()
                        self.setupTap()
                    } else {
                        self.fail("未获得音频访问授权。请在 系统设置 → 隐私与安全性 → 系统音频录制 里允许系统监视器。")
                    }
                }
            }
        default:
            fail("未获得音频访问授权。请在 系统设置 → 隐私与安全性 → 系统音频录制 里允许系统监视器。")
        }
    }

    func stop() {
        guard shouldRun else { return }
        shouldRun = false
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
        rebuildWork?.cancel()
        setupQueue.async { [weak self] in
            guard let self else { return }
            self.rebuildWork?.cancel()
            self.removeOutputListeners()
            self.teardown()
            self.releaseFFT()
        }
    }

    /// 必须在 setupQueue 上调用。minimumInterval 把静音自愈和设备切换的风暴分开:
    /// 静音自愈拆得太勤,会把下一次播放的通路弄断。
    /// forSilence 为真时改用退避间隔,试过几次就停,等下次真正开始播放再试。
    private func scheduleRebuild(reason: String, minimumInterval: TimeInterval, forSilence: Bool = false) {
        guard shouldRun else { return }
        let interval: TimeInterval
        if forSilence {
            guard let silenceInterval = Self.silenceHealInterval(after: deafHeals) else { return }
            interval = silenceInterval
        } else {
            interval = minimumInterval
        }
        let elapsed = Date().timeIntervalSince(lastRecreateAt)
        rebuildWork?.cancel()
        if elapsed < interval {
            let work = DispatchWorkItem { [weak self] in
                self?.scheduleRebuild(reason: reason, minimumInterval: interval, forSilence: forSilence)
            }
            rebuildWork = work
            setupQueue.asyncAfter(deadline: .now() + (interval - elapsed), execute: work)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            self.lastRecreateAt = Date()
            self.lastNonZeroAt = Date()
            if forSilence { self.deafHeals += 1 } else { self.deafHeals = 0 }
            self.healCount += 1
            self.updateDiag("⑥ 第 \(self.healCount) 次重挂抽头（\(reason)）")
            self.teardown()
            guard self.shouldRun else { return }
            self.setupTap()
        }
        rebuildWork = work
        setupQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 静音自愈间隔:8 秒、30 秒、2 分钟,之后放弃,直到播放状态重新跳变。
    private static func silenceHealInterval(after heals: Int) -> TimeInterval? {
        let steps: [TimeInterval] = [8, 30, 120]
        guard heals >= 0, heals < steps.count else { return nil }
        return steps[heals]
    }

    private func installOutputListeners() {
        guard outputDeviceListener == nil else { return }
        outputDeviceListener = addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self, let device = Self.defaultOutputDevice(), device != self.watchedOutputID else { return }
            self.scheduleRebuild(reason: "输出设备切换", minimumInterval: 1)
        }
        systemOutputListener = addSystemListener(kAudioHardwarePropertyDefaultSystemOutputDevice) { [weak self] in
            guard let self, let device = Self.systemOutputDevice(), device != self.watchedSystemOutputID else { return }
            self.scheduleRebuild(reason: "系统提示音设备切换", minimumInterval: 1)
        }
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector,
                                   _ body: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in body() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, setupQueue, listener)
        return listener
    }

    private func removeOutputListeners() {
        if let listener = outputDeviceListener {
            removeSystemListener(kAudioHardwarePropertyDefaultOutputDevice, listener)
            outputDeviceListener = nil
        }
        if let listener = systemOutputListener {
            removeSystemListener(kAudioHardwarePropertyDefaultSystemOutputDevice, listener)
            systemOutputListener = nil
        }
        unwatchOutputRate()
    }

    private func removeSystemListener(_ selector: AudioObjectPropertySelector,
                                      _ listener: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, setupQueue, listener)
    }

    /// 耳机或蓝牙切换采样率时,旧抽头还按原来的速率走,播放会直接没声。
    private func watchOutputRate() {
        unwatchOutputRate()
        guard let device = Self.defaultOutputDevice() else { return }
        watchedRate = Self.nominalRate(of: device)
        watchedOutputID = device
        watchedSystemOutputID = Self.systemOutputDevice() ?? 0
        rateDeviceID = device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let rate = Self.nominalRate(of: device)
            guard rate > 0, abs(rate - self.watchedRate) > 1 else { return }
            self.scheduleRebuild(reason: "输出采样率变了", minimumInterval: 1)
        }
        rateListener = listener
        AudioObjectAddPropertyListenerBlock(device, &address, setupQueue, listener)
    }

    private func unwatchOutputRate() {
        guard let listener = rateListener, rateDeviceID != 0 else {
            rateListener = nil
            rateDeviceID = 0
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(rateDeviceID, &address, setupQueue, listener)
        rateListener = nil
        rateDeviceID = 0
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        copyDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func systemOutputDevice() -> AudioDeviceID? {
        copyDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    private static func copyDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    /// 默认输出上有没有客户端正在播放。没人播放时扬声器这项是 0。
    private static func outputIsRunning() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    private static func nominalRate(of device: AudioDeviceID) -> Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static func secondsSince(_ tick: UInt64) -> Double {
        guard tick != 0 else { return .infinity }
        return Double(mach_absolute_time() &- tick) * ticksToSeconds
    }

    // MARK: 装配

    private func copyStringProperty(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func copyStreamFormat(of object: AudioObjectID, selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        return asbd
    }

    private func setupTap() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [] as [AudioObjectID])
        description.name = "SysMon 声音律动"
        let uuid = UUID()
        description.uuid = uuid
        description.muteBehavior = .unmuted      // 声音照常播放,我们只读一份
        description.isPrivate = true             // 仅本进程可见
        // 全局立体声混音:排除列表为空 = 所有进程。这两个标志若没立上,
        // 空的 processes 会被当成"一个进程都不收",回调全是 0。
        description.isExclusive = true
        description.isMixdown = true
        description.isMono = false

        var tap = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { fail("创建音频抽头失败(\(status))"); return }
        tapID = tap
        let tapUID = copyStringProperty(of: tap, selector: AudioObjectPropertySelector(0x74756964)) ?? uuid.uuidString
        updateDiag("① 抽头 uid=\(tapUID) exclusive=\(description.isExclusive) mixdown=\(description.isMixdown) mono=\(description.isMono) 排除 \(description.processes.count) 个进程")

        guard let tapFormat = copyStreamFormat(of: tap, selector: tapFormatSelector,
                                                scope: kAudioObjectPropertyScopeGlobal) else {
            fail("读取抽头格式失败")
            teardown()
            return
        }
        tapChannelCount = max(1, Int(tapFormat.mChannelsPerFrame))

        // 聚合设备只挂这个抽头,并用它当主时钟。把系统输出设备拉进来当主设备时,
        // 回调收到的是麦克风(通常是静音),播放中的声音进不了缓冲,RMS 一直是 0。
        let aggregate: [String: Any] = [
            "uid": "local.sysmon.pulse." + uuid.uuidString,
            "name": "SysMon 声音律动",
            "private": true,
            "master": tapUID,
            "taps": [["uid": tapUID, "drift": 1] as [String: Any]],
            "tapautostart": 1,
        ]

        var device = AudioDeviceID(0)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            fail("创建聚合设备失败(\(status))")
            return
        }
        aggregateID = device
        updateDiag("② 聚合设备创建成功")

        // 回调里的缓冲布局跟聚合设备的输入格式走,不跟抽头自己的格式走。
        guard let asbd = copyStreamFormat(of: device, selector: kAudioDevicePropertyStreamFormat,
                                          scope: kAudioObjectPropertyScopeInput),
              asbd.mSampleRate > 0 else {
            fail("读取音频格式失败")
            teardown()
            return
        }
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            fail(String(format: "音频格式不是 32 位浮点(flags=0x%x)", asbd.mFormatFlags))
            teardown()
            return
        }
        sampleRate = asbd.mSampleRate
        channels = max(1, Int(asbd.mChannelsPerFrame))
        interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        // 设备里只有抽头,从第 0 路读完全部声道。
        tapChannelCount = channels
        tapChannelOffset = 0
        updateDiag(String(format: "③ 格式 %.0f Hz · %d 声道 · flags=0x%x · %@",
                          sampleRate, channels, asbd.mFormatFlags,
                          interleaved ? "交错" : "非交错"))

        let setupStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, ioQueue) { [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }
            self.ingest(inputData, output: outputData)
        }
        guard setupStatus == noErr, let proc = ioProcID,
              AudioDeviceStart(device, proc) == noErr else {
            fail("启动音频读取失败(\(setupStatus))")
            teardown()
            return
        }

        setupAnalysis()
        watchOutputRate()
        updateDiag("⑤ IO 已启动,等待数据…")
        DispatchQueue.main.async {
            PulseModel.shared.running = true
            PulseModel.shared.statusMessage = nil
        }
    }

    private func setupAnalysis() {
        if window.count != fftSize {
            window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            fftReal = [Float](repeating: 0, count: fftSize)
            fftImag = [Float](repeating: 0, count: fftSize)
            magnitudes = [Float](repeating: 0, count: fftSize / 2)
        }
        // FFTSetup 是 vDSP 的裸指针,直接赋新值不会释放旧的。点数固定,
        // 只建一次;重挂抽头时若每次都重建,一套旋转因子大约 190KB,
        // 几小时就能堆到几百 MB。
        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        }
        bandRanges = Self.makeBandRanges(sampleRate: sampleRate, fftSize: fftSize)

        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        timer.schedule(deadline: .now(), repeating: 0.033)
        timer.setEventHandler { [weak self] in self?.analyze() }
        timer.resume()
        analysisTimer = timer
    }

    private func fail(_ message: String) {
        teardown()
        DispatchQueue.main.async {
            PulseModel.shared.running = false
            PulseModel.shared.statusMessage = message
        }
    }

    private func teardown() {
        analysisTimer?.cancel()
        analysisTimer = nil
        unwatchOutputRate()
        if aggregateID != 0 {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            ioProcID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        lastIOTick.withLockUnchecked { $0 = 0 }
        gate.withLockUnchecked {
            ringFilled = 0
            ringWrite = 0
            display = Array(repeating: 0, count: PulseModel.bandCount)
            peaks = Array(repeating: 0, count: PulseModel.bandCount)
            displayLevel = 0
        }
        DispatchQueue.main.async {
            PulseModel.shared.running = false
            PulseModel.shared.frame.update(Array(repeating: 0, count: PulseModel.bandCount))
        }
    }

    /// 关掉律动时释放 FFT。必须在 setupQueue 上、且 teardown 已停掉分析定时器之后调用。
    private func releaseFFT() {
        analysisQueue.sync {
            if let setup = fftSetup {
                vDSP_destroy_fftsetup(setup)
                fftSetup = nil
            }
        }
    }

    // MARK: 采集(IO 实时线程)

    /// 最近一次回调里,输入/输出两侧各自的缓冲数和峰值。分析线程读,IO 线程写。
    private var lastInputBuffers = 0
    private var lastOutputBuffers = 0
    private var lastOutputPeak: Float = 0
    private var nullInputCallbacks = 0

    private func ingest(_ list: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        lastIOTick.withLockUnchecked { $0 = mach_absolute_time() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer<AudioBufferList>(mutating: list))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        // 实时线程不能等锁。分析线程拿着锁时丢掉这一小段,立刻把回调还回去,
        // 否则系统混音会被堵住,表现就是声音放不出来。
        guard gate.withLockIfAvailableUnchecked({ () -> Bool in
            self.ingestLocked(buffers, outputs: outputs)
            return true
        }) != nil else { return }
    }

    /// 调用方已拿着 gate。
    private func ingestLocked(_ buffers: UnsafeMutableAudioBufferListPointer,
                              outputs: UnsafeMutableAudioBufferListPointer) {
        ioCallbacks += 1
        lastInputBuffers = buffers.count
        lastOutputBuffers = outputs.count
        lastOutputPeak = max(lastOutputPeak, peak(of: outputs))
        guard !buffers.isEmpty, buffers[0].mData != nil else {
            nullInputCallbacks += 1
            return
        }
        // 格式报的声道数有时不含抽头,实际缓冲更多。放宽后才能把窗口挪过去。
        if !interleaved, buffers.count > channels { channels = buffers.count }
        noteBufferPeaks(buffers)
        if !interleaved {
            // 每声道一个 buffer。硬件输入在前,只平均抽头那几路。
            let start = min(tapChannelOffset, buffers.count)
            let end = min(buffers.count, start + tapChannelCount)
            guard start < end else { return }
            var pointers: [UnsafePointer<Float>] = []
            var frames = Int.max
            for b in start..<end {
                guard let data = buffers[b].mData else { continue }
                let count = Int(buffers[b].mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                frames = min(frames, count)
                pointers.append(UnsafePointer(data.assumingMemoryBound(to: Float.self)))
            }
            guard !pointers.isEmpty, frames < Int.max else { return }
            let scale = 1 / Float(pointers.count)
            totalFrames += frames
            for i in 0..<frames {
                var v: Float = 0
                for p in pointers { v += p[i] }
                push(v * scale)
            }
        } else {
            // 交错格式:一帧 channels 个样本,抽头从 tapChannelOffset 起。
            guard let data = buffers[0].mData else { return }
            let pointer = data.assumingMemoryBound(to: Float.self)
            let total = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let stride = max(channels, 1)
            let tapCount = max(1, min(tapChannelCount, stride - min(tapChannelOffset, stride)))
            let tapStart = min(tapChannelOffset, stride - tapCount)
            let scale = 1 / Float(tapCount)
            var i = 0
            while i + stride <= total {
                var v: Float = 0
                for c in 0..<tapCount { v += pointer[i + tapStart + c] }
                push(v * scale)
                i += stride
            }
            totalFrames += i / stride
        }
    }

    private func peak(of buffers: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let pointer = data.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < count {
                peak = max(peak, abs(pointer[i]))
                i += 16
            }
        }
        return peak
    }

    /// 顺手记下各缓冲的峰值(抽样),好判断声音是不是在别的声道上。
    private func noteBufferPeaks(_ buffers: UnsafeMutableAudioBufferListPointer) {
        if !interleaved {
            for (index, buffer) in buffers.enumerated() where index < bufferPeaks.count {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                let pointer = data.assumingMemoryBound(to: Float.self)
                var peak = bufferPeaks[index]
                var i = 0
                while i < count {
                    peak = max(peak, abs(pointer[i]))
                    i += 16
                }
                bufferPeaks[index] = peak
            }
        } else if let data = buffers[0].mData {
            let pointer = data.assumingMemoryBound(to: Float.self)
            let total = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let stride = max(channels, 1)
            var i = 0
            while i + stride <= total {
                for c in 0..<min(stride, bufferPeaks.count) {
                    bufferPeaks[c] = max(bufferPeaks[c], abs(pointer[i + c]))
                }
                i += stride * 16
            }
        }
    }

    /// 抽头那几路是静音、但别的声道有声音时,把窗口挪到最响的那一路上。
    private func realignTapChannelsIfNeeded(sliceRMS rms: Float) {
        let (peaks, current, width, channelCount) = gate.withLockUnchecked { () -> ([Float], Int, Int, Int) in
            let peaks = bufferPeaks
            bufferPeaks = Array(repeating: 0, count: bufferPeaks.count)
            return (peaks, tapChannelOffset, tapChannelCount, channels)
        }
        guard rms < 1e-4 else { return }
        guard let loud = peaks.enumerated().max(by: { $0.element < $1.element }),
              loud.element > 1e-3 else { return }
        let windowEnd = current + width
        guard loud.offset < current || loud.offset >= windowEnd else { return }
        let shifted = max(0, min(loud.offset, max(0, channelCount - width)))
        gate.withLockUnchecked { tapChannelOffset = shifted }
    }

    private func push(_ sample: Float) {
        ring[ringWrite] = sample
        ringWrite = (ringWrite + 1) & ringMask
        if ringFilled < ring.count { ringFilled += 1 }
    }

    private func latestSamples(_ count: Int) -> [Float]? {
        gate.withLockUnchecked { () -> [Float]? in
        guard ringFilled >= count else { return nil }
        var result = [Float](repeating: 0, count: count)
        let start = (ringWrite - count + ring.count) & ringMask
        for i in 0..<count { result[i] = ring[(start + i) & ringMask] }
        return result
        }
    }

    /// 只在扬声器正在出声时重挂。没人播放就拆抽头,下一次播放有时会直接没声。
    private func considerRebuild() {
        let playing = Self.outputIsRunning()
        let now = Date()
        if playing {
            if !sawOutputRunning {
                outputRunningSince = now
                sawOutputRunning = true
                deafHealsClear = true
                setupQueue.async { [weak self] in self?.deafHeals = 0 }
            }
        } else {
            if sawOutputRunning || !deafHealsClear {
                sawOutputRunning = false
                deafHealsClear = true
                setupQueue.async { [weak self] in self?.deafHeals = 0 }
            }
            return
        }
        guard now.timeIntervalSince(outputRunningSince) > 2.5 else { return }
        let ioAge = Self.secondsSince(lastIOTick.withLockUnchecked { $0 })
        let silentFor = now.timeIntervalSince(lastNonZeroAt)
        let stalled = ioAge > 2.5
        let deaf = silentFor > 2.5
        guard stalled || deaf else {
            if !deafHealsClear {
                deafHealsClear = true
                setupQueue.async { [weak self] in self?.deafHeals = 0 }
            }
            return
        }
        if stalled {
            setupQueue.async { [weak self] in
                self?.scheduleRebuild(reason: "正在播放,但抽头回调停了", minimumInterval: 8)
            }
            return
        }
        // 回调还在、只是全 0。设备被占着但没有可听内容时也会这样。
        // 每 8 秒拆一次抽头会把播放通路弄断,所以静音只试几次。
        deafHealsClear = false
        setupQueue.async { [weak self] in
            self?.scheduleRebuild(reason: "正在播放,但抽头全是静音", minimumInterval: 8, forSilence: true)
        }
    }

    // MARK: 频谱分析(分析线程)

    private func analyze() {
        guard var samples = latestSamples(fftSize) else { return }
        // 去掉直流,免得最低那几根条被偏移量顶满。响度也在去直流之后算,
        // 这样静音判断和以前做完 FFT 再算 RMS 是同一口径。
        var dc: Float = 0
        vDSP_meanv(samples, 1, &dc, vDSP_Length(samples.count))
        if dc != 0 {
            var neg = -dc
            vDSP_vsadd(samples, 1, &neg, &samples, 1, vDSP_Length(samples.count))
        }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let floorDB: Float = -50     // 低于这档算没声音,条纹高度为 0
        let rangeDB: Float = 50      // -50 dB → 0,0 dB(满幅)→ 1,中间有高低
        let rmsDB = 20 * log10(max(rms, 1e-7))
        let audible = rmsDB >= floorDB

        var next = display
        if audible, let setup = fftSetup {
            // 实数 FFT(vDSP_fft_zrip)的打包输入:偶数位样本进 real,奇数位进 imag。
            for i in 0..<fftSize / 2 {
                fftReal[i] = samples[2 * i] * window[2 * i]
                fftImag[i] = samples[2 * i + 1] * window[2 * i + 1]
            }
            let half = vDSP_Length(fftSize / 2)
            fftReal.withUnsafeMutableBufferPointer { real in
                fftImag.withUnsafeMutableBufferPointer { imag in
                    var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // 未归一的幅度大约是「采样幅度 × 点数」,普通音量也会算出几十 dB,
                    // 再一截断就整根贴满。除以点数后 1.0 才是满幅。
                    var scale = Float(1) / Float(fftSize)
                    vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, half)
                    vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, half)
                    split.imagp[0] = 0
                    vDSP_zvabs(&split, 1, &magnitudes, 1, half)
                }
            }
            for (b, range) in bandRanges.enumerated() {
                var sum: Float = 0
                for bin in range { sum += magnitudes[bin] }
                let mean = sum / Float(max(1, range.count))
                let db = 20 * log10(max(mean, 1e-7))
                let value = Double(max(0, min(1, (db - floorDB) / rangeDB)))
                // 快攻慢放:往上立刻跟上,往下落到静音线就归零,不留一根底。
                let released = display[b] * 0.74
                var shown = max(value, released)
                if shown < 0.02 { shown = 0 }
                next[b] = shown
                peaks[b] = max(shown, peaks[b] * 0.90)
            }
        } else {
            // 没声音就不做 FFT,只把还没收完的条放下去。
            for b in display.indices {
                let released = display[b] * 0.55
                next[b] = released < 0.02 ? 0 : released
                peaks[b] = next[b] == 0 ? 0 : peaks[b] * 0.7
            }
        }
        let level = audible ? Double(max(0, min(1, (rmsDB - floorDB) / rangeDB))) : 0
        let releasedLevel = audible ? max(level, displayLevel * 0.74) : displayLevel * 0.55
        displayLevel = releasedLevel < 0.02 ? 0 : releasedLevel

        let changed = next != display
        display = next
        if rms > 1e-4 || (next.max() ?? 0) > 0.002 { lastNonZeroAt = Date() }
        if changed {
            let bands = next
            DispatchQueue.main.async {
                PulseModel.shared.frame.update(bands)
            }
        }
        noteDiagnostics(rms: rms)
    }

    /// 每秒把分析侧诊断推到设置页。频谱条不订这份数据。
    private func noteDiagnostics(rms: Float) {
        guard Date().timeIntervalSince(lastDiagAt) > 1 else { return }
        lastDiagAt = Date()
        let (loudest, callbacks) = gate.withLockUnchecked { () -> (Float, Int) in
            let loudest = bufferPeaks.max() ?? 0
            lastOutputPeak = 0
            return (loudest, ioCallbacks)
        }
        considerRebuild()
        realignTapChannelsIfNeeded(sliceRMS: rms)
        updateDiag(String(format: "回调 %d 次 · rms=%.4f · 输入峰值 %.4f · 重挂 %d 次",
                          callbacks, rms, loudest, healCount))
    }

    /// 40Hz–16kHz 之间 24 个对数等比频段对应的 FFT bin 区间。
    private static func makeBandRanges(sampleRate: Double, fftSize: Int) -> [Range<Int>] {
        let minF = 40.0
        let maxF = min(16000.0, sampleRate / 2)
        return (0..<PulseModel.bandCount).map { b in
            let f0 = minF * pow(maxF / minF, Double(b) / Double(PulseModel.bandCount))
            let f1 = minF * pow(maxF / minF, Double(b + 1) / Double(PulseModel.bandCount))
            let bin0 = max(1, Int((f0 * Double(fftSize) / sampleRate).rounded(.down)))
            let bin1 = max(bin0 + 1, Int((f1 * Double(fftSize) / sampleRate).rounded(.down)))
            return bin0..<min(bin1, fftSize / 2)
        }
    }
}
