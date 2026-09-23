import Foundation

extension Double {
    /// 占用率，一位小数。卡片、详情和「今天峰值」那句话共用。
    var percentText: String { String(format: "%.1f %%", self) }
}
