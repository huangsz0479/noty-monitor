# SysMon — 系统监视器

基于 [noty](https://github.com/aimen08/noty)(MIT 许可)改造的 macOS 系统监视器,
贴边常驻形态。noty 的便签数据层已移除,完整移植了它的贴边交互机制
(静止 pill → 扇形展开 → 拉出详情)并接上系统监控数据,
macOS 与 Windows 分目录。macOS 仍用命令行构建(`mac/build.sh`,无需 Xcode)。

## 使用

- 平时只有屏幕右下角一个 14pt 宽的小圆点,里面是每张指标卡专属色的细彩条。
- 鼠标划到右下角边缘:指标卡按 42ms 依次扇形展开(瓦片式叠压、统一倾斜 3°),
  卡片上实时显示 CPU%、内存%、网速、磁盘用量、电量(无电池的机器自动隐藏)、进程数,网络面板可查本机内网 IP。
- 点击卡片:详情面板从边缘弹出——CPU 曲线与拆分、内存曲线与构成、
  进程表(搜索/排序/强制退出)。Esc 或点击其他应用收回。
- 多显示器每块屏一个 dock;右键小圆点可打开带完整功能的窗口或退出。

## 功能

- **进程列表**:全部进程的名称 / PID / 用户 / CPU% / 内存 / 线程数,
  表头点击排序,支持按名称、PID、用户搜索,可切换"仅我的进程"。
- **CPU 页**:系统 CPU 使用率实时曲线(用户/系统/空闲拆分、负载均值、核数、开机时长)。
- **内存页**:已用内存实时曲线(联动、已压缩、可清理、物理空闲、交换分区明细)。
- **进程管理**:选中进程强制退出(SIGKILL),带确认与失败提示。
- **网络**:全机上下行速率实时曲线(绿=下载实线,蓝=上传虚线),按网卡拆分
  (sysctl `NET_RT_IFLIST2` 网卡计数器求差)。
- **电池**:电量条、充电/接电状态、剩余时间(IOPowerSources 公开接口),
  台式机自动不显示。
- **开机自启**:右键小圆点即可开关(SMAppService)。
- 刷新间隔可选 1 / 2 / 5 秒,⌘R 立即刷新。

数据全部来自公开接口:`sysctl`(进程枚举、页面统计、交换、开机时间)、
`libproc`(每进程 CPU 时间与驻留内存)、`host_statistics(64)`(CPU tick)、
`getloadavg`(负载)。CPU% 为相邻两次采样的差值,口径与活动监视器一致
(100% = 单核满载,多核可超过 100%)。

## 构建

需要 macOS 15+ 与 Xcode Command Line Tools(需含 macOS 26 SDK,即 Xcode 26+;
应用本身仅支持 macOS 26+):

```bash
./mac/build.sh          # release 构建 → mac/build/SysMon.app
./mac/build.sh debug    # 快速构建
./mac/build.sh run      # 构建并启动
```

仓库根目录的 `./build.sh` 会转到 `mac/build.sh`。`./build.sh win` 构建 Windows 工程(`win/`)。

## 与原版 noty 的关系

- 保留:`build.sh` 编译链路、`Main.swift` / `AppDelegate.swift` 的 NSApplication 装配模式。
- 删除:便签数据层(SQLite/AES)、贴边 deck UI、编辑器、云同步、快捷键、Sparkle 更新等。
- 新增:采集层(`SystemMetrics` / `ProcessSampler`)、状态层(`MonitorStore`)、界面(`MonitorView`)。

上游许可证见 `LICENSE`。
