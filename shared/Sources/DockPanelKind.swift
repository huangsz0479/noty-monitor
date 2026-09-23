import Foundation

/// 拉出详情面板的种类。贴边卡、提醒和设置共用这一份名单。
enum DockPanelKind: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    case network = "网络"
    case disk = "磁盘"
    case io = "I/O"
    case battery = "电池"
    case glm = "智谱"
    case java = "Java"
    case processes = "进程"
    case note = "便签"
    var id: String { rawValue }
}
