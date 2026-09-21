import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var dockManager: EdgeDockManager!
    private var fullWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        dockManager = EdgeDockManager()
        MonitorStore.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false    // 贴边 dock 常驻,关掉完整窗口不退出
    }

    // MARK: Actions

    /// 贴边 dock 的右键菜单 / 菜单栏入口:打开带完整功能的窗口。
    @objc func openFullWindow() {
        NSApp.setActivationPolicy(.regular)
        if fullWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "系统监视器"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.setFrameAutosaveName("SysMonMainWindow")
            w.delegate = self
            w.contentView = NSHostingView(rootView: MonitorView(store: MonitorStore.shared))
            w.center()
            fullWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        fullWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 完整窗口关掉后回到无 Dock 图标的常驻形态。
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    @objc func refreshNowMenu() { MonitorStore.shared.sampleNow() }

    @objc func openSettings() { SettingsWindow.shared.show() }

    /// 菜单每次打开都会重新校验:开机自启的勾选态跟随当前真实状态,
    /// 不再停留在启动时定格的值(右键菜单切换后主菜单也能跟上)。
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleLaunchAtLogin) {
            item.state = launchAtLoginEnabled ? .on : .off
        }
        return true
    }

    // MARK: 开机自启

    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("SysMon: 设置开机自启失败 — \(error.localizedDescription)")
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "系统监视器 (SysMon)"
        alert.informativeText = "版本 \(version)\n基于 noty(MIT 许可)改造的贴边系统监视器。\n鼠标划到屏幕右边缘展开指标卡。"
        alert.runModal()
    }

    // MARK: Main menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于系统监视器", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "打开完整窗口", action: #selector(openFullWindow), keyEquivalent: "n")
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "立即刷新", action: #selector(refreshNowMenu), keyEquivalent: "r")
        let login = appMenu.addItem(withTitle: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = launchAtLoginEnabled ? .on : .off
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出系统监视器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in appMenu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
