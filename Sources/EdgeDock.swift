import AppKit
import SwiftUI
import Combine

// MARK: - State

/// 拉出详情面板的种类。
enum DockPanelKind: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    case network = "网络"
    case disk = "磁盘"
    case battery = "电池"
    case processes = "进程"
    var id: String { rawValue }
}

enum EdgeDockState: Equatable {
    case rest
    case fan
    case expanded(DockPanelKind)

    var rank: Int {
        switch self {
        case .rest: return 0
        case .fan: return 1
        case .expanded: return 2
        }
    }
    var expandedKind: DockPanelKind? {
        if case .expanded(let kind) = self { return kind }
        return nil
    }
}

final class EdgeDockModel: ObservableObject {
    @Published var state: EdgeDockState = .rest
    @Published var edge: DockEdge
    /// hover 的那张卡:拉高并把具体数值亮出来(hover,不是 click;click 仍开详情面板)。
    @Published var hoveredCard: DockPanelKind?
    @Published var revealTick = 0       // bumped to restage the fan animation
    @Published var fanHeight: CGFloat = 0   // 卡片列实测自然高度

    init(edge: DockEdge) { self.edge = edge }
}

// MARK: - Geometry

/// 贴边 dock 的全部尺寸,数值沿用 noty 的 DeckGeom 比例。
enum DockGeom {
    // Rest — 贴边的 14pt 小圆点
    static let pillWidth: CGFloat = 14
    static let pillPad: CGFloat = 7
    static let dashHeight: CGFloat = 14
    static let dashWidth: CGFloat = 7
    static let dashGap: CGFloat = 5
    static var pillHeight: CGFloat {
        let n = EdgeDockCards.cards.count
        return pillPad * 2 + CGFloat(n) * dashHeight + CGFloat(n - 1) * dashGap
    }

    // Fan — noty 原版形态:30pt 宽的竖排彩纸条,瓦片叠压,统一 3° 倾角
    static let tabWidth: CGFloat = 30
    static let tabLap: CGFloat = 6      // 叠压量必须小于 MetricTab 的上下留白(7pt)
    static let cogSize: CGFloat = 24
    static let cogGap: CGFloat = 8
    static let fanWidth: CGFloat = 50
    /// 卡片向屏幕边缘外多画的一段,防止倾斜时在贴边处露缝。
    static let bleed: CGFloat = 14
    static let leanDegrees: Double = 3.0
    /// pill 停靠在右下角,避开原版 noty 在右边缘中部的默认位置。
    static let pillBottomMargin: CGFloat = 16

    /// 下缘停靠时与右下角的留白,比左右缘更贴角。
    static let bottomCornerInset: CGFloat = 4

    /// 下缘停靠:pill 横躺,彩条并排成一排。
    static var horizontalPillSize: CGSize {
        let n = CGFloat(EdgeDockCards.cards.count)
        return CGSize(width: pillPad * 2 + n * dashWidth + max(0, n - 1) * dashGap,
                      height: dashHeight + pillPad * 2)
    }

    // Expanded — 拉出的详情面板
    static let expandedWidth: CGFloat = 332
    static let panelContentWidth: CGFloat = 264

    /// 进程表三列需要宽纸,其余面板维持窄条。
    static func panelWidth(_ kind: DockPanelKind) -> CGFloat {
        kind == .processes ? 440 : panelContentWidth
    }
    static func panelHeight(_ kind: DockPanelKind) -> CGFloat {
        switch kind {
        case .cpu: return 330
        case .memory: return 366
        case .network: return 398
        case .disk: return 300
        case .battery: return 220
        case .processes: return 560
        }
    }
}

// MARK: - Panel

/// 无边框、非激活的贴边面板(机制同 noty 的 DeckPanel)。
/// canBecomeKey 必须重写,否则拉出的详情面板收不到键盘事件(Esc、搜索框)。
final class EdgeDockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                  // 阴影由 SwiftUI 按卡片绘制
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // .statusBar 才能盖住全屏应用;.fullScreenAuxiliary 让面板能加入全屏空间。
        level = .statusBar
        collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

// MARK: - Tracking container

/// 持有驱动 rest → fan 的 tracking area。命中测试委托给 SwiftUI 宿主视图,
/// 空白区域保持点击穿透(机制同 noty 的 DeckContentView)。
final class EdgeDockContentView: NSView {
    weak var controller: EdgeDockController?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(at: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit    // 空白区域不吞掉点击
    }

    /// 面板不激活时点击也要生效——用户往往在别的应用里划过来。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// SwiftUI 宿主,同样不吞首次点击。
final class EdgeDockHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) { super.init(rootView: rootView) }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

/// 每块屏一个贴边 dock(机制同 noty 的 DeckController,按 CGDirectDisplayID 索引)。
final class EdgeDockController: NSObject {
    let displayID: CGDirectDisplayID
    let model: EdgeDockModel

    private let panel = EdgeDockPanel()
    private var hosting: EdgeDockHostingView<EdgeDockRootView>!
    private var container: EdgeDockContentView!
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var idleTimer: Timer?
    private var lastActivity = Date()
    private var lastPointer = NSEvent.mouseLocation
    private var exitWork: DispatchWorkItem?     // 防抖:确认指针真的离开了
    private var shrinkWork: DispatchWorkItem?   // 收起动画播完后再缩回小条

    weak var manager: EdgeDockManager?

    /// 永久展开开启时,静止态就是 .fan——卡片常驻,hover 只在收起时有意义。
    private var restingState: EdgeDockState { CardSettings.shared.alwaysShown ? .fan : .rest }

    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.model = EdgeDockModel(edge: CardSettings.shared.dockEdge)
        super.init()

        container = EdgeDockContentView()
        container.controller = self
        container.autoresizingMask = [.width, .height]

        hosting = EdgeDockHostingView(rootView: EdgeDockRootView(dock: model, controller: self))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)

        panel.contentView = container
        model.state = restingState
        layout(for: model.state)
        panel.orderFrontRegardless()
    }

    /// 设置切换后应用新的静止态:开启立即展开;关闭等指针离开后收回。
    func applyRestingState() {
        switch model.state {
        case .rest where restingState == .fan:
            setState(.fan)
        case .fan where restingState == .rest:
            if hotZone.contains(NSEvent.mouseLocation) { startIdleWatch() }
            else { setState(.rest) }
        default:
            break
        }
    }

    /// 切换停靠边缘:先收回静止态,再换向重排(SwiftUI 侧随 model.edge 换向)。
    func applyEdge(_ edge: DockEdge) {
        guard edge != model.edge else { return }
        model.hoveredCard = nil
        setState(restingState)
        model.edge = edge
        layout()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        idleTimer?.invalidate()
        panel.orderOut(nil)
    }

    // MARK: Layout

    func layout() { layout(for: model.state) }

    func layout(for state: EdgeDockState) {
        guard let screen else { return }
        let full = screen.frame
        let vis = screen.visibleFrame

        let frame: NSRect
        switch model.edge {
        case .right:
            frame = verticalFrame(state, full: full, vis: vis, fromRight: true)
        case .left:
            frame = verticalFrame(state, full: full, vis: vis, fromRight: false)
        case .bottom:
            frame = bottomFrame(state, full: full, vis: vis)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    /// 左右两缘:面板是一条贴边全高窄条,只有停靠方向不同。
    private func verticalFrame(_ state: EdgeDockState, full: NSRect, vis: NSRect,
                               fromRight: Bool) -> NSRect {
        switch state {
        case .rest:
            // 静止的面板本身就是贴边检测条:pill 画在边缘,其余部分透明、可穿透。
            let x = fromRight ? full.maxX - DockGeom.pillWidth : full.minX
            return NSRect(x: x, y: round(vis.minY + DockGeom.pillBottomMargin),
                          width: DockGeom.pillWidth, height: DockGeom.pillHeight)
        case .fan:
            let w = DockGeom.expandedWidth
            return NSRect(x: fromRight ? full.maxX - w : full.minX,
                          y: vis.minY, width: w, height: vis.height)
        case .expanded(let kind):
            let w = DockGeom.tabWidth + DockGeom.panelWidth(kind)
            return NSRect(x: fromRight ? full.maxX - w : full.minX,
                          y: vis.minY, width: w, height: vis.height)
        }
    }

    /// 下缘:pill/卡片横躺成一排,面板锚在右下角向左、向上生长。
    /// 贴屏幕真正的底边(而不是 visibleFrame 底边)——用户要的是盖在
    /// Dock 区域上的屏幕边缘。
    private func bottomFrame(_ state: EdgeDockState, full: NSRect, vis: NSRect) -> NSRect {
        switch state {
        case .rest:
            let size = DockGeom.horizontalPillSize
            return NSRect(x: full.maxX - size.width - DockGeom.bottomCornerInset,
                          y: full.minY, width: size.width, height: size.height)
        case .fan:
            let side = DockGeom.expandedWidth
            return NSRect(x: full.maxX - side, y: full.minY, width: side, height: side)
        case .expanded(let kind):
            let w = DockGeom.panelWidth(kind) + DockGeom.tabWidth
            let h = DockGeom.tabWidth + DockGeom.panelHeight(kind)
            return NSRect(x: full.maxX - w, y: full.minY, width: w, height: h)
        }
    }

    // MARK: Transitions

    private func setState(_ new: EdgeDockState) {
        let old = model.state
        guard old != new else { return }
        shrinkWork?.cancel(); shrinkWork = nil

        if new.rank >= old.rank {
            layout(for: new)
            if new == .fan {
                model.state = new
                model.revealTick &+= 1
            } else {
                // 面板要先完成 resize *并渲染出来* 再让详情滑入。main.async
                // 不够——SwiftUI 会把 resize 和状态变化合并成一次 pass,
                // 宽度动画会把整个 deck 拖着走。隔两帧保持两件事分开。
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 / 60.0) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        self.model.state = new
                    }
                }
            }
        } else {
            // 先在全尺寸上播完退出动画,再把面板缩回小条。
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                self.model.state = new
            }
            let work = DispatchWorkItem { [weak self] in self?.layout() }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        if new.expandedKind != nil {
            installKeyMonitor(); installOutsideMonitor()
        } else {
            removeKeyMonitor(); removeOutsideMonitor()
        }
        // 只有高于静止态才需要"无人看管自动收起"的轮询。
        if new.rank > restingState.rank { startIdleWatch() } else { stopIdleWatch() }
    }

    private func noteActivity() { lastActivity = Date() }

    /// 面板比扇形卡片宽得多,tracking area 分辨不出指针是否离开了卡片列,
    /// 用轮询对照热区代替(避免全局 mouse-moved 监听及其权限问题)。
    private func startIdleWatch() {
        guard idleTimer == nil else { return }
        lastActivity = Date()
        lastPointer = NSEvent.mouseLocation
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSEvent.mouseLocation
            if self.model.state == .fan, !self.hotZone.contains(now) {
                self.collapse(); return
            }
            if abs(now.x - self.lastPointer.x) > 2 || abs(now.y - self.lastPointer.y) > 2 {
                self.lastPointer = now
                self.lastActivity = Date()
            }
            // 正悬停在某张卡上看数值时不算"无人看管",不自动收起。
            if self.model.state == .fan, self.model.hoveredCard == nil,
               Date().timeIntervalSince(self.lastActivity) > 3.0 {
                self.collapse()
            }
        }
    }

    private func stopIdleWatch() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// dock 实际占据的贴边窄条,"离开 dock" 以它为准。
    private var hotZone: NSRect {
        let f = panel.frame
        let depth = DockGeom.fanWidth + 20
        switch model.edge {
        case .right:
            return NSRect(x: f.maxX - depth, y: f.minY, width: depth, height: f.height)
        case .left:
            return NSRect(x: f.minX, y: f.minY, width: depth, height: f.height)
        case .bottom:
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: depth)
        }
    }

    func pointerEntered() {
        noteActivity()
        exitWork?.cancel(); exitWork = nil
        shrinkWork?.cancel(); shrinkWork = nil
        guard model.state == .rest else { layout(); return }
        manager?.dockDidActivate(self)
        setState(.fan)
    }

    func pointerExited() {
        // 永久展开模式下指针离开不收起;拉出的详情保持打开,直到 Esc/外部点击。
        guard model.state == .fan, restingState != .fan else { return }
        // resize 时 tracking area 会误报,延迟确认指针确实离开了。
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .fan else { return }
            if !self.hotZone.contains(NSEvent.mouseLocation) {
                self.setState(self.restingState)
            }
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func toggle(_ kind: DockPanelKind) {
        noteActivity()
        if model.state.expandedKind == kind { collapse() } else { expand(kind) }
    }

    func expand(_ kind: DockPanelKind) {
        noteActivity()
        manager?.dockDidActivate(self)
        setState(.expanded(kind))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 关闭详情 → 退回扇形,卡片留在原位;只有完全离开才收起。
    func collapse() {
        if model.state.expandedKind != nil {
            setState(.fan)
            NSApp.deactivate()
        } else {
            setState(restingState)
        }
    }

    /// 整个收回到静止态(永久展开时即保持扇形)。
    func dismiss() {
        let wasExpanded = model.state.expandedKind != nil
        setState(restingState)
        if wasExpanded { NSApp.deactivate() }
    }

    func collapseToRest() { setState(restingState) }

    // MARK: Key & outside monitoring

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.model.state.expandedKind != nil,
                  self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 {          // Esc
                self.collapse()
                return nil
            }
            return event
        }
    }

    /// 点击其他应用时收起详情。纯鼠标的全局监听不需要辅助功能权限。
    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.state.expandedKind != nil else { return }
            DispatchQueue.main.async { self.dismiss() }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Context menu

    func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开完整窗口", action: #selector(AppDelegate.openFullWindow), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(AppDelegate.openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(AppDelegate.refreshNowMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let login = NSMenuItem(title: "开机自启", action: #selector(AppDelegate.toggleLaunchAtLogin), keyEquivalent: "")
        login.target = NSApp.delegate
        login.state = ((NSApp.delegate as? AppDelegate)?.launchAtLoginEnabled ?? false) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出系统监视器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = NSApp.delegate
        }
        NSMenu.popUpContextMenu(menu, with: event, for: container)
    }
}

// MARK: - Manager

/// 每块目标屏维护一个贴边 dock,屏幕增减或参数变化时重建。
final class EdgeDockManager {
    private(set) var docks: [CGDirectDisplayID: EdgeDockController] = [:]
    private var bag = Set<AnyCancellable>()

    init() {
        CardSettings.shared.$alwaysShown
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.docks.values.forEach { $0.applyRestingState() }
            }
            .store(in: &bag)
        CardSettings.shared.$dockEdge
            .receive(on: RunLoop.main)
            .sink { [weak self] edge in
                self?.docks.values.forEach { $0.applyEdge(edge) }
            }
            .store(in: &bag)
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    private func rebuild() {
        let ids = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        for id in Array(docks.keys) where !ids.contains(id) {
            docks.removeValue(forKey: id)
        }
        for id in ids where docks[id] == nil {
            let dock = EdgeDockController(displayID: id)
            dock.manager = self
            docks[id] = dock
        }
        docks.values.forEach { $0.layout() }
    }

    /// 同一时间只展开一个——指针进入哪个屏就收起其他的。
    func dockDidActivate(_ active: EdgeDockController) {
        for d in docks.values where d !== active { d.collapseToRest() }
    }
}
