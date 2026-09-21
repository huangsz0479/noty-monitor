import AppKit
import SwiftUI

// MARK: - 停靠边缘

/// 贴边 dock 停靠的位置(顶缘让给菜单栏):左右两缘或两个下角。
enum DockEdge: String, CaseIterable, Identifiable {
    case left, right, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .left: return "左缘"
        case .right: return "右缘"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
    /// 是否为下角停靠(卡片横排站在屏幕底边)。
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
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

    /// dock 停靠的屏幕边缘。
    @Published var dockEdge: DockEdge {
        didSet {
            UserDefaults.standard.set(dockEdge.rawValue, forKey: "dockEdge")
        }
    }

    private init() {
        if let raw = UserDefaults.standard.stringArray(forKey: "enabledCards") {
            let stored = Set(raw.compactMap(DockPanelKind.init(rawValue:)))
            enabled = stored.isEmpty ? Set(DockPanelKind.allCases) : stored
        } else {
            enabled = Set(DockPanelKind.allCases)
        }
        alwaysShown = UserDefaults.standard.bool(forKey: "deckAlwaysShown")
        hoverRevealsValue = UserDefaults.standard.object(forKey: "cardValuesOnHover") as? Bool ?? true
        // 旧版"下缘"(bottom)即右下角。
        let storedEdge = UserDefaults.standard.string(forKey: "dockEdge")
        dockEdge = storedEdge == "bottom"
            ? .bottomRight
            : (storedEdge.flatMap(DockEdge.init(rawValue:)) ?? .right)
    }

    /// 按固定顺序返回启用的卡片;没有电池硬件时电池卡永远不出现。
    var cards: [DockPanelKind] {
        DockPanelKind.allCases
            .filter { enabled.contains($0) }
            .filter { $0 != .battery || Self.hasBattery }
    }
}

enum EdgeDockCards {
    static var cards: [DockPanelKind] { CardSettings.shared.cards }
}

// MARK: - 设置视图

struct SettingsView: View {
    @ObservedObject var settings = CardSettings.shared
    private let hasBattery = CardSettings.hasBattery

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
            Text("贴边卡片")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 10) {
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
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(kind == .battery && !hasBattery)
                }
            }

            Divider()

            Toggle(isOn: $settings.alwaysShown) {
                Text("永久展开卡片")
            }
            .toggleStyle(.checkbox)

            Text("开启后卡片常驻屏幕边缘,无需鼠标划过。")

            Divider()

            Toggle(isOn: $settings.hoverRevealsValue) {
                Text("悬停显示数值")
            }
            .toggleStyle(.checkbox)

            Text("开启后卡片只显示名称,悬停到哪张卡,哪张拉高显示具体数值;关闭则数值常显。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            Text("小圆点与卡片停靠在哪条屏幕边缘,切换后立即生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("鼠标划到屏幕右下角展开卡片,点击卡片查看详情。至少保留一张卡片。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 250, alignment: .leading)
    }
}

// MARK: - 设置窗口

final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 480),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
