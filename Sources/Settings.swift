import AppKit
import SwiftUI

// MARK: - 卡片可见性设置

/// 哪些指标卡显示在贴边 dock 上,持久化到 UserDefaults。
final class CardSettings: ObservableObject {
    static let shared = CardSettings()

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

    private init() {
        if let raw = UserDefaults.standard.stringArray(forKey: "enabledCards") {
            let stored = Set(raw.compactMap(DockPanelKind.init(rawValue:)))
            enabled = stored.isEmpty ? Set(DockPanelKind.allCases) : stored
        } else {
            enabled = Set(DockPanelKind.allCases)
        }
        alwaysShown = UserDefaults.standard.bool(forKey: "deckAlwaysShown")
    }

    /// 按固定顺序返回启用的卡片;没有电池硬件时电池卡永远不出现。
    var cards: [DockPanelKind] {
        DockPanelKind.allCases
            .filter { enabled.contains($0) }
            .filter { $0 != .battery || BatteryReader.read() != nil }
    }
}

enum EdgeDockCards {
    static var cards: [DockPanelKind] { CardSettings.shared.cards }
}

// MARK: - 设置视图

struct SettingsView: View {
    @ObservedObject var settings = CardSettings.shared
    private let hasBattery = BatteryReader.read() != nil

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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
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
