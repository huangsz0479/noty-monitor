import Foundation

// MARK: - 智谱 GLM 编码套餐余量

/// 一个配额窗口(每 5 小时 / 本周 / 本月工具调用)的用量。
struct GLMQuotaWindow: Equatable, Identifiable {
    enum Kind: String {
        case tokens = "TOKENS_LIMIT"
        case time = "TIME_LIMIT"
    }

    let kind: Kind
    /// 同类窗口的第几条:TOKENS_LIMIT 第 0 条是"每 5 小时",第 1 条是"本周"。
    let slot: Int
    let usedPercent: Double
    let remainingPercent: Double
    let resetDate: Date
    /// 窗口名,按接口的 unit/number 推(3=小时、6=周、5=月)。
    let label: String
    /// TIME_LIMIT 窗口的次数明细,如"14 / 1000 次";TOKENS_LIMIT 为 nil。
    let remainingText: String?

    var id: String { "\(kind.rawValue)#\(slot)" }
    var usedFraction: Double { usedPercent / 100 }
}

/// 一次查询的完整结果:窗口列表 + 错误信息 + 拉取时间。
/// 相等判断不含 fetchedAt——数据没变就不算变,避免无谓的重绘。
struct GLMPlanStatus: Equatable {
    var windows: [GLMQuotaWindow] = []
    /// 套餐档位(lite/pro/max 之类),接口原样返回小写。
    var level: String?
    var error: String?
    var fetchedAt = Date()

    /// 每 5 小时窗口:最影响"当下还能不能继续用"的那个,卡片数值取它。
    var fiveHour: GLMQuotaWindow? {
        windows.first { $0.kind == .tokens && $0.slot == 0 }
    }

    static func == (lhs: GLMPlanStatus, rhs: GLMPlanStatus) -> Bool {
        lhs.windows == rhs.windows && lhs.level == rhs.level && lhs.error == rhs.error
    }
}

/// 查询智谱 open.bigmodel.cn 的套餐配额余量。该接口没写进正式文档,调用
/// 方式与智谱官方 zai-coding-plugins 仓库 glm-plan-usage 插件的
/// query-usage.mjs 一致:GET /api/monitor/usage/quota/limit,Authorization
/// 头原样放 API Key(不带 Bearer)。
///
/// 实测(2026-09)返回是信封对象:
/// `{"code":200,"msg":"操作成功","success":true,"data":{"level":"pro",
///   "limits":[{"type","unit","number","percentage","nextResetTime"},…]}}`
/// ——percentage 是已用百分比,nextResetTime 是毫秒时间戳;与旧帖流传的
/// 裸数组 used_percent/reset_time 格式不同,以此文件为准。
enum GLMPlanReader {
    private static let endpoint = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!

    private struct RawEnvelope: Decodable {
        let code: Int?
        let msg: String?
        let success: Bool?
        let data: RawData?
    }

    private struct RawData: Decodable {
        let limits: [RawLimit]?
        let level: String?
    }

    private struct RawLimit: Decodable {
        let type: String
        let unit: Int?
        let number: Int?
        /// 已用百分比(TOKENS/TIME 两种窗口都有)。
        let percentage: Double?
        /// 以下三项只有 TIME_LIMIT 窗口带:总额度 / 已用 / 剩余(调用次数)。
        let usage: Double?
        let currentValue: Double?
        let remaining: Double?
        let nextResetTime: Double?
    }

    /// 异步拉取,结果在主队列回调。key 为空时回调"未设置"状态。
    static func fetch(apiKey: String, completion: @escaping (GLMPlanStatus) -> Void) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(GLMPlanStatus(error: "未设置 API Key"))
            return
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, _, error in
            let status: GLMPlanStatus
            if let error {
                status = GLMPlanStatus(error: "网络错误:\(error.localizedDescription)")
            } else if let data {
                status = parse(data)
            } else {
                status = GLMPlanStatus(error: "接口没有返回数据")
            }
            DispatchQueue.main.async { completion(status) }
        }.resume()
    }

    private static func parse(_ data: Data) -> GLMPlanStatus {
        guard let envelope = try? JSONDecoder().decode(RawEnvelope.self, from: data) else {
            return GLMPlanStatus(error: "返回格式无法解析")
        }
        // 鉴权失败等错误:{"code":1001,"msg":"…","success":false}。
        if envelope.success == false || (envelope.code.map { $0 != 200 } ?? false) {
            return GLMPlanStatus(error: envelope.msg ?? "接口返回失败")
        }
        let rawLimits = envelope.data?.limits ?? []
        var tokenSlots = 0
        let windows: [GLMQuotaWindow] = rawLimits.compactMap { raw in
            guard let kind = GLMQuotaWindow.Kind(rawValue: raw.type) else { return nil }
            let slot = kind == .tokens ? tokenSlots : 0
            if kind == .tokens { tokenSlots += 1 }
            let used = raw.percentage ?? 0
            return GLMQuotaWindow(
                kind: kind, slot: slot,
                usedPercent: used,
                remainingPercent: max(0, 100 - used),
                resetDate: Date(timeIntervalSince1970: (raw.nextResetTime ?? 0) / 1000),
                label: windowLabel(kind: kind, slot: slot, unit: raw.unit, number: raw.number),
                remainingText: remainingText(raw))
        }
        if windows.isEmpty {
            return GLMPlanStatus(error: "接口没有返回任何配额窗口")
        }
        return GLMPlanStatus(windows: windows, level: envelope.data?.level)
    }

    /// unit 实测取值:3=小时(TOKENS)、6=周(TOKENS)、5=月(TIME);
    /// 出现未知取值时退回按条目位置命名。
    private static func windowLabel(kind: GLMQuotaWindow.Kind, slot: Int,
                                    unit: Int?, number: Int?) -> String {
        switch kind {
        case .tokens:
            if unit == 3, let n = number, n > 0 { return "每 \(n) 小时" }
            if unit == 6 { return "本周" }
            return slot == 0 ? "每 5 小时" : "本周"
        case .time:
            return "本月工具"
        }
    }

    private static func remainingText(_ raw: RawLimit) -> String? {
        guard raw.type == GLMQuotaWindow.Kind.time.rawValue, let usage = raw.usage, usage > 0 else {
            return nil
        }
        let left = raw.remaining ?? max(0, usage - (raw.currentValue ?? 0))
        return "\(Int(left)) / \(Int(usage)) 次"
    }
}
