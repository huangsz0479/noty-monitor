# AGENTS.md — SysMon 项目记忆

## 项目是什么

**SysMon（系统监视器）**：macOS 贴边常驻的系统监视器，由便签应用
[noty](https://github.com/aimen08/noty)（MIT）改造而来。复用了 noty 的贴边交互
（静止小圆点 → 鼠标划过扇形展开卡片 → 点击拉出详情面板）和命令行构建方案，
删掉了它的便签数据层（SQLite/AES、编辑器、云同步、Sparkle 更新等），接上
系统监控数据：CPU / 内存 / 网络 / 磁盘 / 电池 / 进程表（搜索、排序、强制退出）。

形态：平时只有屏幕右缘一个 14pt 小圆点（无 Dock 图标的 accessory App），
hover 展开 6 张指标卡，点击弹出详情面板；另有右键菜单打开的完整窗口。
每块显示器一个 dock。

## 构建与运行

无 Xcode 工程、无 Package.swift、零第三方依赖。`build.sh` 用 swiftc 直接把
`Sources/*.swift` 逐架构编译成 app（**Sources/ 下所有 .swift 都会被编进去，
不能放不参与编译的文件**）：

```bash
./build.sh          # release，默认 universal（arm64 + x86_64）
./build.sh debug    # 只编本机架构，不优化，快
./build.sh run      # 构建并重启 App
```

- 版本号经环境变量 `MARKETING_VERSION` / `BUILD_NUMBER` 注入 Info.plist；
  签名身份 `CODESIGN_IDENTITY`（默认 ad-hoc `-`）。
- 开发环境要求 macOS 15+ 与 Xcode CLT；deployment target 为 `macosx26.0`
  （build.sh 里 `-target`），用了 SwiftUI Charts（macOS 14+ API）。
- **没有测试套件**（noty 的 Tests/ 已随改造删除）。改完至少跑一次
  `./build.sh debug` 验证可编译。

## 架构（数据流：Sampler → MonitorStore → SwiftUI）

- `Main.swift` — `@main`，NSApplication 装配，accessory 策略。
- `AppDelegate.swift` — 组装 `EdgeDockManager`、启动 `MonitorStore`；
  完整窗口（980×640，`MonitorView`）、主菜单、SMAppService 开机自启。
- **采集层**（无状态或有差分状态的 sampler，只公开系统 API）：
  - `SystemMetrics.swift` — `SystemSnapshot` + `SystemSampler`
    （sysctl 页面统计 / `host_statistics64` CPU tick / `getloadavg`）。
  - `ProcessSampler.swift` — libproc 枚举进程，算相邻两次采样的 CPU%。
  - `NetworkSampler.swift` — sysctl `NET_RT_IFLIST2` 每网卡字节计数求差。
  - `DiskAndIP.swift` — `DiskReader`（URL resourceValues 卷容量）、
    `LocalIPReader`（getifaddrs）、`BatteryReader`（IOPowerSources）。
- **状态层** `MonitorStore.swift` — 单例 ObservableObject。DispatchSourceTimer
  在串行后台队列采样，回主队列写 `@Published`；历史曲线各存 150 点
  （`historyLimit`）。刷新间隔 1/2/5s，`sampleNow()` 给 ⌘R。
- **贴边 dock**：`EdgeDock.swift`（每屏一个 manager + rest/fan/panel 状态机）、
  `EdgeDockViews.swift`（SwiftUI 指标卡，沿用 noty 纸色调色板，每卡专属色）。
- **完整窗口** `MonitorView.swift` — SwiftUI Charts 曲线 + 六个标签页 +
  进程表（排序/搜索/SIGKILL 强杀）。
- `Settings.swift` — `CardSettings`（卡片可见性、常驻展开、刷新间隔，
  UserDefaults 持久化，key：`enabledCards` / `deckAlwaysShown` 等）。

## 关键约定

- **注释与 UI 文案全部用简体中文**；命名、代码风格保持 Swift 惯例。
- CPU% 口径与活动监视器一致：100% = 单核满载，多核可超 100%（进程与
  系统两级都是相邻采样差值）。
- 只用系统公开接口（sysctl / libproc / host_statistics / IOKit / SMAppService），
  不要引入第三方依赖或私有 API。
- 采样有差分状态（NetworkSampler、ProcessSampler 的 last* 字段），只能在
  MonitorStore 的串行队列上调；`@Published` 一律主线程写。
- 台式机无电池时电池卡/电池页自动隐藏（`EdgeDockCards.cards` 决定），
  完整窗口标签页跟随它。

## 当前状态（2026-09）

noty → SysMon 的大改造**尚未提交**：HEAD 还停在 noty 1.9.0
（"Release 1.9.0: update appcast"），工作区删除了全部便签代码、站点、
媒体与脚本，新增了上述 SysMon 源码。`.github/workflows/` 里的
build.yml / release.yml / pages.yml 继承自 noty，尚未核对是否适配。
