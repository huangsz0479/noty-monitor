import AppKit
import Security
import SwiftUI

// MARK: - 停靠边缘

/// 贴边 dock 停靠的位置(顶缘让给菜单栏):左右两缘或右下角。
enum DockEdge: String, CaseIterable, Identifiable {
    case left, right, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .left: return "左缘"
        case .right: return "右缘"
        case .bottomRight: return "右下角"
        }
    }
    /// 是否为下角停靠(卡片横排站在屏幕底边)。
    var isBottom: Bool { self == .bottomRight }
}

// MARK: - 卡片可见性设置

/// 哪些指标卡显示在贴边 dock 上,持久化到 UserDefaults。
final class CardSettings: ObservableObject {
    static let shared = CardSettings()

    /// 电池有无在进程生命周期内基本不变,只探测一次——cards 会被 SwiftUI
    /// 每次渲染调用,不能每次都走 IOKit。
    static let hasBattery = BatteryReader.read() != nil

    @Published var enabled: Set<DockPanelKind> {
        didSet {
            UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "enabledCards")
        }
    }

    /// 永久展开(noty 的"保持展开"):开启后卡片常驻屏幕边缘,无需 hover。
    @Published var alwaysShown: Bool {
        didSet {
            UserDefaults.standard.set(alwaysShown, forKey: "deckAlwaysShown")
        }
    }

    /// 悬停显示数值:开启后卡片只显示名称,悬停哪张哪张拉高亮出数值;
    /// 关闭则所有卡常显数值(改版前行为)。
    @Published var hoverRevealsValue: Bool {
        didSet {
            UserDefaults.standard.set(hoverRevealsValue, forKey: "cardValuesOnHover")
        }
    }

    /// 声音律动是否显示在每块屏的左下角。不占贴边卡片。
    @Published var pulseEnabled: Bool {
        didSet {
            UserDefaults.standard.set(pulseEnabled, forKey: "pulseEnabled")
        }
    }

    /// 律动用随机配色。关闭时用下面的自选色,每根条同色。
    @Published var pulseColorRandom: Bool {
        didSet {
            UserDefaults.standard.set(pulseColorRandom, forKey: "pulseColorRandom")
        }
    }

    /// 随机配色的种子。换一组就换一个种子,条的颜色跟着变,但不会每帧乱跳。
    @Published var pulseColorSeed: Int {
        didSet {
            UserDefaults.standard.set(pulseColorSeed, forKey: "pulseColorSeed")
        }
    }

    @Published var pulseRed: Double {
        didSet { UserDefaults.standard.set(pulseRed, forKey: "pulseRed") }
    }
    @Published var pulseGreen: Double {
        didSet { UserDefaults.standard.set(pulseGreen, forKey: "pulseGreen") }
    }
    @Published var pulseBlue: Double {
        didSet { UserDefaults.standard.set(pulseBlue, forKey: "pulseBlue") }
    }

    var pulseColor: Color {
        Color(red: pulseRed, green: pulseGreen, blue: pulseBlue)
    }

    /// dock 停靠的屏幕边缘。
    @Published var dockEdge: DockEdge {
        didSet {
            UserDefaults.standard.set(dockEdge.rawValue, forKey: "dockEdge")
        }
    }

    /// 左右缘小圆点离可见区底边的距离(点)。下角停靠不用。
    /// 默认贴着底边留一点缝,拖动后记住;比屏幕矮时由布局再夹取。
    @Published var dockVerticalOffset: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(dockVerticalOffset), forKey: "dockVerticalOffset")
        }
    }

    /// 智谱开放平台 API Key(bigmodel.cn 控制台),用于查询 GLM 编码套餐
    /// 余量;留空时智谱卡不出现。优先存系统钥匙串。
    @Published var glmApiKey: String {
        didSet {
            guard glmApiKey != oldValue else { return }
            APIKeyStore.save(glmApiKey)
        }
    }

    private init() {
        let storedCards = UserDefaults.standard.stringArray(forKey: "enabledCards")
        let noteIntroduced = UserDefaults.standard.object(forKey: "noteCardIntroduced") != nil
        var initial: Set<DockPanelKind>
        if let raw = storedCards {
            let stored = Set(raw.compactMap(DockPanelKind.init(rawValue:)))
            initial = stored.isEmpty ? Set(DockPanelKind.allCases) : stored
        } else {
            initial = Set(DockPanelKind.allCases)
        }
        // 旧偏好里没有「便签」。第一次见到这张卡时默认打开,之后尊重用户的勾选。
        // init 里给 enabled 赋值不会走 didSet,所以这里自己写回。
        if !noteIntroduced {
            initial.insert(.note)
            UserDefaults.standard.set(true, forKey: "noteCardIntroduced")
            UserDefaults.standard.set(initial.map(\.rawValue), forKey: "enabledCards")
        }
        enabled = initial
        // 以前律动是一张卡:勾过就接着开,没存过卡片列表时默认开。
        let pulseOn = UserDefaults.standard.object(forKey: "pulseEnabled") == nil
            ? (storedCards?.contains("律动") ?? true)
            : UserDefaults.standard.bool(forKey: "pulseEnabled")
        if UserDefaults.standard.object(forKey: "pulseEnabled") == nil {
            UserDefaults.standard.set(pulseOn, forKey: "pulseEnabled")
        }
        pulseEnabled = pulseOn
        pulseColorRandom = UserDefaults.standard.object(forKey: "pulseColorRandom") as? Bool ?? true
        let seed = UserDefaults.standard.object(forKey: "pulseColorSeed") as? Int
            ?? Int.random(in: 1...999_999)
        if UserDefaults.standard.object(forKey: "pulseColorSeed") == nil {
            UserDefaults.standard.set(seed, forKey: "pulseColorSeed")
        }
        pulseColorSeed = seed
        pulseRed = UserDefaults.standard.object(forKey: "pulseRed") as? Double ?? (214.0 / 255)
        pulseGreen = UserDefaults.standard.object(forKey: "pulseGreen") as? Double ?? (66.0 / 255)
        pulseBlue = UserDefaults.standard.object(forKey: "pulseBlue") as? Double ?? (60.0 / 255)
        alwaysShown = UserDefaults.standard.bool(forKey: "deckAlwaysShown")
        hoverRevealsValue = UserDefaults.standard.object(forKey: "cardValuesOnHover") as? Bool ?? true
        // 旧版"下缘"(bottom)和已去掉的左下角,都归到右下角。
        let storedEdge = UserDefaults.standard.string(forKey: "dockEdge")
        if storedEdge == "bottom" || storedEdge == "bottomLeft" {
            dockEdge = .bottomRight
            UserDefaults.standard.set(DockEdge.bottomRight.rawValue, forKey: "dockEdge")
        } else {
            dockEdge = storedEdge.flatMap(DockEdge.init(rawValue:)) ?? .right
        }
        if let stored = UserDefaults.standard.object(forKey: "dockVerticalOffset") as? Double,
           stored.isFinite {
            dockVerticalOffset = CGFloat(stored)
        } else {
            dockVerticalOffset = DockGeom.pillBottomMargin
        }
        glmApiKey = APIKeyStore.load()
    }

    /// 按固定顺序返回启用的卡片;没有电池硬件时电池卡永远不出现,
    /// 没配 API Key 时智谱卡永远不出现。
    var cards: [DockPanelKind] {
        DockPanelKind.allCases
            .filter { enabled.contains($0) }
            .filter { $0 != .battery || Self.hasBattery }
            .filter { $0 != .glm || !glmApiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

enum EdgeDockCards {
    static var cards: [DockPanelKind] { CardSettings.shared.cards }
}

// MARK: - 设置视图

/// 设置页分三页:卡片 / 智谱 / 律动。避免一页从头滚到尾。
struct SettingsView: View {
    @ObservedObject var settings = CardSettings.shared
    private let hasBattery = CardSettings.hasBattery
    @State private var page: Page = .cards

    enum Page: String, CaseIterable, Identifiable {
        case cards = "卡片"
        case glm = "智谱"
        case pulse = "律动"
        var id: String { rawValue }
    }

    private var glmKeyMissing: Bool {
        settings.glmApiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var edgeHint: String {
        let drag = settings.dockEdge.isBottom ? "" : "按住小圆点或卡片可以上下拖动位置。"
        return "鼠标划到屏幕\(settings.dockEdge.label)展开卡片,点击卡片查看详情。\(drag)机器忙、电量低或套餐快用完时,对应卡片会自己探出来。至少保留一张卡片。"
    }

    private func binding(_ kind: DockPanelKind) -> Binding<Bool> {
        Binding(
            get: { settings.enabled.contains(kind) },
            set: { on in
                // 至少保留一张卡。
                if !on && settings.enabled.count <= 1 { return }
                if on { settings.enabled.insert(kind) } else { settings.enabled.remove(kind) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("页面", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch page {
            case .cards: cardsPage
            case .glm: glmPage
            case .pulse: pulsePage
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
    }

    // MARK: 卡片页

    @ViewBuilder
    private var cardsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("显示哪些卡")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(DockPanelKind.allCases) { kind in
                    Toggle(isOn: binding(kind)) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(kind.palette.dash)
                                .frame(width: 14, height: 14)
                            Text(kind.rawValue)
                            if kind == .battery && !hasBattery {
                                Text("(未检测到电池)")
                                    .foregroundStyle(.secondary)
                            }
                            if kind == .glm && glmKeyMissing {
                                Text("(未设置 API Key)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled((kind == .battery && !hasBattery) || (kind == .glm && glmKeyMissing))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Toggle(isOn: $settings.alwaysShown) {
                Text("永久展开卡片")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.hoverRevealsValue) {
                Text("悬停显示数值")
            }
            .toggleStyle(.checkbox)

            Divider()

            Text("停靠边缘")
                .font(.system(size: 13, weight: .semibold))

            Picker("停靠边缘", selection: $settings.dockEdge) {
                ForEach(DockEdge.allCases) { edge in
                    Text(edge.label).tag(edge)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(edgeHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 智谱页

    @ViewBuilder
    private var glmPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API Key")
                .font(.system(size: 13, weight: .semibold))

            SecureField("API Key", text: $settings.glmApiKey, prompt: Text("粘贴 bigmodel.cn 的 API Key"))
                .textFieldStyle(.roundedBorder)

            Text("在 bigmodel.cn 控制台「API Keys」页创建后粘贴到这里(保存在系统钥匙串,写不进去时才退回本机偏好设置)。设置后卡片与详情面板会显示编码套餐的每 5 小时 / 本周 / 本月额度余量;剩得少时这张卡会自己探出来。留空则不显示智谱卡。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 律动页

    @ViewBuilder
    private var pulsePage: some View {
        PulseSettingsStatus()
    }
}

/// 律动页的实时状态:开关提示 + 装配/运行诊断(哪一步没走通一眼可见)。
struct PulseSettingsStatus: View {
    @ObservedObject private var settings = CardSettings.shared
    @ObservedObject private var model = PulseModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("显示在左下角", isOn: $settings.pulseEnabled)
                .toggleStyle(.checkbox)

            Picker("颜色", selection: $settings.pulseColorRandom) {
                Text("随机").tag(true)
                Text("自选").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.pulseColorRandom {
                Button("换一组颜色") {
                    settings.pulseColorSeed = Int.random(in: 1...999_999)
                }
            } else {
                ColorPicker("颜色", selection: pulseColorBinding, supportsOpacity: false)
            }

            Text("状态")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                Circle()
                    .fill(model.running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout)
            }

            if !model.diagnostics.isEmpty {
                Text(model.diagnostics)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("打开后,频谱直接铺在每块屏幕的左下角,不占用贴边卡片。没声音时条纹高度为 0。只读取这台 Mac 正在播放的声音;首次开启会请求「系统音频录制」——只允许「麦克风」时缓冲全是静音。不录音不存储,开启期间状态栏有橙色指示灯。被拒绝时到 系统设置 → 隐私与安全性 → 系统音频录制 里允许系统监视器。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if let message = model.statusMessage { return message }
        return model.running ? "正在律动" : "未开启或静默中"
    }

    private var pulseColorBinding: Binding<Color> {
        Binding(
            get: { settings.pulseColor },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
                settings.pulseRed = Double(ns.redComponent)
                settings.pulseGreen = Double(ns.greenComponent)
                settings.pulseBlue = Double(ns.blueComponent)
            }
        )
    }
}

// MARK: - 设置窗口

final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            // 窗口尺寸取自内容的 fittingSize:加设置项时不会放不下或留白。
            let host = NSHostingView(rootView: SettingsView())
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                 width: ceil(size.width),
                                                 height: ceil(size.height)),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "设置"
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - API Key

/// 智谱 API Key 的存取。钥匙串失败时退回 UserDefaults,避免设置丢了卡就没了。
enum APIKeyStore {
    private static let service = "local.sysmon.SysMon"
    private static let account = "glmApiKey"
    private static let defaultsKey = "glmApiKey"

    static func load() -> String {
        if let key = readKeychain() {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return key
        }
        let legacy = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if !legacy.isEmpty, writeKeychain(legacy) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        return legacy
    }

    static func save(_ value: String) {
        if writeKeychain(value) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(value, forKey: defaultsKey)
        }
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// 空字符串表示删掉。返回是否写进了钥匙串。
    private static func writeKeychain(_ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return true }
        var query = base
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
