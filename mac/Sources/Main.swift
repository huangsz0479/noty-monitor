import AppKit

@main
enum SysMonMain {
    /// NSApplication.delegate is unowned — hold the delegate here for the process lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // 贴边 dock 形态:无 Dock 图标、无主窗口,像 noty 一样常驻屏幕边缘。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
