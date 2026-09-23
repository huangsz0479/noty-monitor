# AGENTS.md — SysMon 项目记忆

## 项目是什么

**SysMon（系统监视器）**：macOS 贴边常驻的系统监视器，由便签应用
[noty](https://github.com/aimen08/noty)（MIT）改造而来。复用了 noty 的贴边交互
（静止小圆点 → 鼠标划过扇形展开卡片 → 点击拉出详情面板）和命令行构建方案，
删掉了它的便签数据层（SQLite/AES、编辑器、云同步、Sparkle 更新等），接上
系统监控数据：CPU / 内存 / 网络 / 磁盘 / 电池 / 进程表（搜索、排序、强制退出）。

目录：`mac/` 是 macOS 应用（贴边窗口、SwiftUI、系统采集），`win/` 是 Windows 应用（Rust + 系统 WebView，贴边窗口和采集都在这里，`cargo run --manifest-path win/Cargo.toml` 或 `./build.sh win`）。`shared/Sources/` 是 macOS 仍在编译的共用服务（提醒规则、智谱余量、进程行和命令行标签）。贴边界面各画各的：macOS 用 SwiftUI，Windows 用同一套纸色、尺寸和扇形节奏。Windows 侧还没有声音律动，也没有单独的 980×640 完整窗口。

形态：平时只有屏幕边缘一个 14pt 小圆点（无 Dock 图标的 accessory App，
停靠位置可选左缘/右缘/右下角，UserDefaults key `dockEdge`，默认
右缘；顶缘让给菜单栏；右下角贴屏幕真底边、盖在 Dock 区域上），hover 展开
6 张系统指标卡（另有 I/O 负载卡、Java JVM 卡、配了智谱 API Key 后的
套餐余量卡，都在设置里开关），点击弹出
详情面板；另有右键菜单打开的完整窗口。每块显示器
一个 dock。左右缘为竖排卡片列（互为镜像），右下角为横排卡片（卡片
直立站在屏幕底边、齿轮在远离角落的一端），三种位置
共用 `CardMetrics` 实测布局，只是定位轴向与锚点不同。

## 构建与运行

无 Xcode 工程、无 Package.swift、macOS 侧零第三方依赖。`mac/build.sh` 用 swiftc 直接把
`mac/Sources/*.swift` 和 `shared/Sources/*.swift` 逐架构编译成 app（**这两个目录下所有 .swift 都会被编进去，
不能放不参与编译的文件**）：

```bash
./mac/build.sh          # release，默认 universal（arm64 + x86_64）
./mac/build.sh debug    # 只编本机架构，不优化，快
./mac/build.sh run      # 构建并重启 App
```

仓库根的 `./build.sh` 不带参数时转发到 `mac/build.sh`。`./build.sh win` 用 cargo 构建 `win/`。

- 版本号经环境变量 `MARKETING_VERSION` / `BUILD_NUMBER` 注入 Info.plist；
  签名身份 `CODESIGN_IDENTITY`（默认 ad-hoc `-`）。
- 开发环境要求 macOS 15+ 与 Xcode CLT；deployment target 为 `macosx26.0`
  （build.sh 里 `-target`），用了 SwiftUI Charts（macOS 14+ API）。
- 翻页测试在 `mac/Tests/`，不参与 `build.sh`。改完至少跑一次
  `./mac/build.sh debug` 验证可编译。

## 架构（数据流：Sampler → MonitorStore → SwiftUI）

下面列的 Swift 文件都在 `mac/Sources/`。例外在 `shared/Sources/`：`DockPanelKind`、`BatteryInfo`、`ProcInfo` / `ProcFilter` / `RuntimeLabels`、`DockSignals`（进程摘要、彩条、提醒）、`GLMPlanUsage`、`percentText`。

- `Main.swift` — `@main`，NSApplication 装配，accessory 策略。
- `AppDelegate.swift` — 组装 `EdgeDockManager`、启动 `MonitorStore`；
  完整窗口（980×640，`MonitorView`）、主菜单、SMAppService 开机自启。
- **采集层**（无状态或有差分状态的 sampler，只公开系统 API）：
  - `SystemMetrics.swift` — `SystemSnapshot` + `SystemSampler`
    （sysctl 页面统计 / `host_statistics64` CPU tick / `getloadavg`）。
  - `ProcessSampler.swift` — libproc 枚举进程，算相邻两次采样的 CPU%。
    路径按 pid 缓存。JVM 看可执行文件名是不是 `java`，node / python 同理，
    `KERN_PROCARGS2` 读命令行提取业务标签（`-jar` 包名、主类末段或脚本文件名），
    存进 `ProcInfo.isJava` / `javaLabel` / `scriptLabel` / `displayName`。
    `digest(of:)` 在采样队列上收成 `ProcessDigest`（进程数、JVM 合计、主导进程）。
  - `NetworkSampler.swift` — sysctl `NET_RT_IFLIST2` 每网卡字节计数求差。
  - `DiskIOSampler.swift` — IOKit 注册表 `IOBlockStorageDriver` 的 Statistics
    （与 iostat 同源）累计字节/操作数求差,得读写速率与 IOPS。
  - `DiskAndIP.swift` — `DiskReader`（URL resourceValues 卷容量）、
    `LocalIPReader`（getifaddrs）、`BatteryReader`（IOPowerSources）。
  - `GLMPlanUsage.swift` — 智谱 GLM 编码套餐余量。调未写进正式文档的
    `GET open.bigmodel.cn/api/monitor/usage/quota/limit`（Authorization 头
    原样放 API Key、不带 Bearer，与智谱官方 zai-coding-plugins 的
    glm-plan-usage 插件同款），返回每 5 小时 / 本周 / 本月工具三个窗口的
    used/remaining 百分比与重置时间。
  - `AudioSpectrumSampler.swift` — 声音律动。CoreAudio Process Tap
    （`AudioHardwareCreateProcessTap` + 私有聚合设备）截取系统正在播放的混音，
    vDSP FFT 出 24 个对数频段，30Hz 发布到独立的 `PulseModel`
    （不进 MonitorStore，避免拖动整列重绘）。频谱不占贴边卡片，由
    `PulseCornerController` 铺在每块屏的左下角（屏幕真底边往上长，不吃点击）。
    开关是 `CardSettings.pulseEnabled`（UserDefaults `pulseEnabled`；
    从旧的「律动」卡勾选迁移）。颜色：`pulseColorRandom` 为真时每根条一个由
    `pulseColorSeed` 决定的稳定随机色，否则用 `pulseRed/Green/Blue` 自选色。
    macOS 26 的抽头走 TCC `kTCCServiceAudioCapture`，
    Info.plist 必须有 `NSAudioCaptureUsageDescription`，否则系统直接拒绝、
    缓冲全是 0（只允许「麦克风」不够）。不录音不存储，开启期间状态栏有橙色指示灯。
- **状态层** `MonitorStore.swift` — 单例 ObservableObject。DispatchSourceTimer
  在串行后台队列采样，回主队列写 `@Published`；历史曲线各存 150 点
  （`historyLimit`）。刷新间隔 1/2/5s（持久化到 UserDefaults key
  `refreshInterval`），`sampleNow()` 给 ⌘R；电池按 10s、卷/IP 按 30s
  降频重读（看时间间隔，不看拍数），且低频数据不变时不重写 `@Published`。
  进程全表只在贴边进程/Java 面板或完整窗口打开时发布（`acquireProcessList` /
  `releaseProcessList`）；卡片读 `digest`。另有 `attention`（CPU 连续 ≥85%
  约三个采样、拔电且电量 ≤20%、智谱 5 小时窗口剩余 ≤15%，带滞回）和
  `dailyPeak`（当天 CPU 峰值一句话）。彩条强度在 `dashLevels`，8 档量化。
  智谱套餐走独立 60s 轮询（自己的队列 + URLSession 异步，不阻塞采样队列），
  API Key 变化时防抖后立即重查，`GLMPlanStatus` 相等判断不含 fetchedAt。
  API Key 存在系统钥匙串（`APIKeyStore`，service `local.sysmon.SysMon`），
  写失败才退回 UserDefaults。
- **贴边 dock**：`EdgeDock.swift`（每屏一个 manager + rest/peek/fan/panel
  状态机。`peek` 在静止且 `attention` 有值、用户还没凑过去看时，只探出那一张卡；
  探出窗口比扇形小，原点与静止 pill 对齐，避免小圆点挪位）、
  `EdgeDockViews.swift`（SwiftUI 指标卡，沿用 noty 纸色调色板，每卡专属色。
  小圆点彩条按 `dashLevels` 深浅变化，被点名的那根呼吸）。
- **完整窗口** `MonitorView.swift` — SwiftUI Charts 曲线 + 标签页（跟随
  贴边卡片）+ 进程表（排序/搜索/SIGKILL 强杀）。
- `Settings.swift` — `CardSettings`（卡片可见性、常驻展开、悬停显示数值、
  智谱 API Key。UserDefaults key：`enabledCards` / `deckAlwaysShown` /
  `cardValuesOnHover`；`glmApiKey` 走钥匙串。电池有无以静态 `hasBattery` 只探测一次，
  `cards` 会被 SwiftUI 每次渲染调用）。悬停显示数值开启时，卡片只显示名称、
  悬停哪张哪张拉高亮出数值（`CardMetrics.displayValues` 过滤），
  关闭则数值常显。

## 关键约定

- **注释与 UI 文案全部用简体中文**；命名、代码风格保持 Swift 惯例。
- CPU% 口径与活动监视器一致：100% = 单核满载，多核可超 100%（进程与
  系统两级都是相邻采样差值）。
- 只用系统公开接口（sysctl / libproc / host_statistics / IOKit / SMAppService / Security），
  不要引入第三方依赖或私有 API。唯一的网络数据源是智谱套餐余量接口
  （公开 HTTP + 用户自配 API Key）。
- 采样有差分状态（NetworkSampler、ProcessSampler、DiskIOSampler 的 last*
  字段），只能在 MonitorStore 的串行队列上调；`@Published` 一律主线程写。
- 台式机无电池时电池卡/电池页自动隐藏（`EdgeDockCards.cards` 决定），
  完整窗口标签页跟随它。

## 当前状态（2026-09）

noty → SysMon 的大改造已提交：先一笔删除全部便签代码、站点、媒体与
脚本，再一笔进入 SysMon 源码，其后的提交是评审优化（性能修复、图标、CI）。

CI 已适配 SysMon：`build.yml` 在 push/PR 时构建并校验 universal
SysMon.app；`release.yml` 改为 workflow_dispatch 手动发版（输入版本号，
打 universal zip 挂 GitHub Release，无 Sparkle/appcast）；`pages.yml`
已随站点删除。两个 workflow 都显式选择 runner 上最新的 Xcode
（部署目标 macosx26.0 需要 macOS 26 SDK）。

App 图标是六色彩条（`mac/Resources/AppIcon.icns` 直接提交，生成脚本未入库）；
`.github` 之外无遗留 noty 资产。仍无测试套件。`CFBundleIdentifier`
还是占位的 `local.sysmon.SysMon`，对外分发前建议换成正式 reverse-DNS。
