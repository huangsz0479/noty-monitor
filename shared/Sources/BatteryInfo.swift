import Foundation

/// 一块在场电池的读数。各平台自己采集，字段保持一致。
struct BatteryInfo: Equatable {
    var percent: Double
    var isCharging: Bool
    var onAC: Bool
    var timeRemainingMinutes: Int?    // nil = 计算中或不可用
}
