import Foundation
import CoreAudio
import Accelerate
import AVFoundation

// MARK: - 声音律动(系统输出频谱)

/// 律动的实时数据。独立于 MonitorStore:30Hz 的发布只触发律动视图重绘,
/// 不拖着整列指标卡每秒重画 30 次。
final class PulseModel: ObservableObject {
    static let shared = PulseModel()
    static let bandCount = 24

    /// 各频段能量 0...1(已做快攻慢放平滑)。
    @Published var bands: [Double] = Array(repeating: 0, count: PulseModel.bandCount)
    /// 频段峰值保持线(衰减更慢,画"冒泡点"用)。
    @Published var peaks: [Double] = Array(repeating: 0, count: PulseModel.bandCount)
    /// 整体响度 0...1。
    @Published var level: Double = 0
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

    // 采样环形缓冲(IO 实时线程写,分析线程读)
    private let lock = NSLock()
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
    /// 自愈:抽头在静默期创建的话,音频服务可能把空混音固定在它身上——
    /// IO 一直有回调但数据全零。检测到这种状态就摘掉重挂一个新抽头。
    private var lastNonZeroAt = Date()
    private var lastRecreateAt = Date.distantPast
    private var lastSeenCallbacks = 0
    private var healCount = 0
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
            setupQueue.async { [weak self] in self?.setupTap() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.setupQueue.async {
                    guard let self, self.shouldRun else { return }
                    if granted {
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
        setupQueue.async { [weak self] in self?.teardown() }
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
        updateDiag("⑤ IO 已启动,等待数据…")
        DispatchQueue.main.async {
            PulseModel.shared.running = true
            PulseModel.shared.statusMessage = nil
        }
    }

    private func setupAnalysis() {
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftReal = [Float](repeating: 0, count: fftSize)
        fftImag = [Float](repeating: 0, count: fftSize)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
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
        lock.lock()
        ringFilled = 0
        ringWrite = 0
        display = Array(repeating: 0, count: PulseModel.bandCount)
        peaks = Array(repeating: 0, count: PulseModel.bandCount)
        displayLevel = 0
        lock.unlock()
        DispatchQueue.main.async {
            PulseModel.shared.running = false
            PulseModel.shared.bands = Array(repeating: 0, count: PulseModel.bandCount)
            PulseModel.shared.peaks = Array(repeating: 0, count: PulseModel.bandCount)
            PulseModel.shared.level = 0
        }
    }

    // MARK: 采集(IO 实时线程)

    /// 最近一次回调里,输入/输出两侧各自的缓冲数和峰值。分析线程读,IO 线程写。
    private var lastInputBuffers = 0
    private var lastOutputBuffers = 0
    private var lastOutputPeak: Float = 0
    private var nullInputCallbacks = 0

    private func ingest(_ list: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer<AudioBufferList>(mutating: list))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        lock.lock()
        ioCallbacks += 1
        lastInputBuffers = buffers.count
        lastOutputBuffers = outputs.count
        lastOutputPeak = max(lastOutputPeak, peak(of: outputs))
        guard !buffers.isEmpty, buffers[0].mData != nil else {
            nullInputCallbacks += 1
            lock.unlock()
            return
        }
        defer { lock.unlock() }
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
        lock.lock()
        let peaks = bufferPeaks
        bufferPeaks = Array(repeating: 0, count: bufferPeaks.count)
        let current = tapChannelOffset
        let width = tapChannelCount
        lock.unlock()
        guard rms < 1e-4 else { return }
        guard let loud = peaks.enumerated().max(by: { $0.element < $1.element }),
              loud.element > 1e-3 else { return }
        let windowEnd = current + width
        guard loud.offset < current || loud.offset >= windowEnd else { return }
        let shifted = max(0, min(loud.offset, max(0, channels - width)))
        lock.lock()
        tapChannelOffset = shifted
        lock.unlock()
    }

    private func push(_ sample: Float) {
        ring[ringWrite] = sample
        ringWrite = (ringWrite + 1) & ringMask
        if ringFilled < ring.count { ringFilled += 1 }
    }

    private func latestSamples(_ count: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard ringFilled >= count else { return nil }
        var result = [Float](repeating: 0, count: count)
        let start = (ringWrite - count + ring.count) & ringMask
        for i in 0..<count { result[i] = ring[(start + i) & ringMask] }
        return result
    }

    // MARK: 频谱分析(分析线程)

    private func analyze() {
        guard var samples = latestSamples(fftSize), let setup = fftSetup else { return }
        // 去掉直流,免得最低那几根条被偏移量顶满。
        var dc: Float = 0
        vDSP_meanv(samples, 1, &dc, vDSP_Length(samples.count))
        if dc != 0 {
            var neg = -dc
            vDSP_vsadd(samples, 1, &neg, &samples, 1, vDSP_Length(samples.count))
        }
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

        let floorDB: Float = -50     // 低于这档算没声音,条纹高度为 0
        let rangeDB: Float = 50      // -50 dB → 0,0 dB(满幅)→ 1,中间有高低
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let rmsDB = 20 * log10(max(rms, 1e-7))
        let audible = rmsDB >= floorDB
        var next = [Double](repeating: 0, count: PulseModel.bandCount)
        if audible {
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
            for b in display.indices {
                let released = display[b] * 0.55
                next[b] = released < 0.02 ? 0 : released
                peaks[b] = next[b] == 0 ? 0 : peaks[b] * 0.7
            }
        }
        let level = audible ? Double(max(0, min(1, (rmsDB - floorDB) / rangeDB))) : 0
        let releasedLevel = audible ? max(level, displayLevel * 0.74) : displayLevel * 0.55

        display = next
        displayLevel = releasedLevel < 0.02 ? 0 : releasedLevel

        // 死抽头自愈:IO 一直在回调、但连续 15 秒数据全零 → 摘掉重挂一个
        // 新抽头。在静默期创建的抽头,音频服务可能把空混音固定在它身上,
        // 音乐开始后也收不到;重挂时音乐在放,就能挂上。真正的静默期 IO 会
        // 整个停掉(ioAlive 不成立),不会触发。30 秒内最多重挂一次。
        let hasSignal = rms > 1e-4 || (next.max() ?? 0) > 0.002
        if hasSignal { lastNonZeroAt = Date() }
        let now = Date()
        let ioAlive = ioCallbacks != lastSeenCallbacks
        lastSeenCallbacks = ioCallbacks
        if !hasSignal, ioAlive,
           now.timeIntervalSince(lastNonZeroAt) > 15,
           now.timeIntervalSince(lastRecreateAt) > 30 {
            lastRecreateAt = now
            lastNonZeroAt = now
            healCount += 1
            updateDiag("⑥ 第 \(healCount) 次自动重挂抽头(有回调但无数据)…")
            setupQueue.async { [weak self] in
                guard let self, self.shouldRun else { return }
                self.teardown()
                guard self.shouldRun else { return }
                self.setupTap()
            }
            return
        }

        // 每秒把分析侧诊断推到面板/设置页:能看到数据是不是真的在流。
        if Date().timeIntervalSince(lastDiagAt) > 1 {
            lastDiagAt = Date()
            lock.lock()
            let loudest = bufferPeaks.max() ?? 0
            lastOutputPeak = 0
            lock.unlock()
            realignTapChannelsIfNeeded(sliceRMS: rms)
            updateDiag(String(format: "回调 %d 次 · rms=%.4f · 输入峰值 %.4f · 重挂 %d 次",
                              ioCallbacks, rms, loudest, healCount))
        }
        DispatchQueue.main.async {
            PulseModel.shared.bands = next
            PulseModel.shared.peaks = self.peaks
            PulseModel.shared.level = self.displayLevel
        }
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
