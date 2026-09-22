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
    case io = "I/O"
    case battery = "电池"
    case glm = "智谱"
    case java = "Java"
    case processes = "进程"
    case note = "便签"
    var id: String { rawValue }
}

enum EdgeDockState: Equatable {
    case rest
    /// 异常时只探出这一张卡,窗口比扇形小,不挡整条屏幕边缘。
    case peek(DockPanelKind)
    case fan
    case expanded(DockPanelKind)

    var rank: Int {
        switch self {
        case .rest: return 0
        case .peek: return 1
        case .fan: return 2
        case .expanded: return 3
        }
    }
    var expandedKind: DockPanelKind? {
        if case .expanded(let kind) = self { return kind }
        return nil
    }
    var peekKind: DockPanelKind? {
        if case .peek(let kind) = self { return kind }
        return nil
    }
}

final class EdgeDockModel: ObservableObject {
    @Published var state: EdgeDockState = .rest
    @Published var edge: DockEdge
    /// hover 的那张卡:拉高并把具体数值亮出来(hover,不是 click;click 仍开详情面板)。
    @Published var hoveredCard: DockPanelKind?
    /// 扇形正在按入场的相反顺序收回。state 仍停在 .fan,列才不会被提前卸掉。
    @Published var closing = false
    @Published var fanHeight: CGFloat = 0   // 卡片列实测自然高度
    /// 左右缘小圆点离可见区底边的距离,已按当前屏幕夹取。下角布局不用。
    @Published var verticalOffset: CGFloat = DockGeom.pillBottomMargin

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
    /// 扇形卡片依次进出的间隔。退场用同一间隔、相反的顺序。
    static let stageInterval: Double = 0.026
    /// 单张卡片弹簧。临界阻尼,response 就是落到贴边的时间,没有回弹把卡片又露出来。
    static let stageSpring: TimeInterval = 0.22
    /// 退场时最右边那张(进程)开始收回的时刻。
    static var fanExitLastDelay: TimeInterval {
        Double(EdgeDockCards.cards.count) * stageInterval
    }
    /// 小圆点在进程卡落到贴边之后再亮。弹簧没走完就亮,看起来就是提前。
    static var pillRevealDelay: TimeInterval {
        fanExitLastDelay + stageSpring
    }
    /// 窗口缩回:进程卡落定、小圆点已经在角落里。
    static var fanExitDuration: TimeInterval {
        pillRevealDelay
    }
    /// 左右缘小圆点离可见区底边的默认距离。用户拖动后改记在 dockVerticalOffset。
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

    /// Java 的 JVM 列表要宽纸(标签是完整类名);贴边进程面板只放前几名,窄一档。
    static func panelWidth(_ kind: DockPanelKind) -> CGFloat {
        switch kind {
        case .processes, .note: return 360
        case .java: return 560
        default: return panelContentWidth
        }
    }
    /// 展开窗口恒取最宽面板的尺寸(换面板不 resize)。
    static var maxPanelWidth: CGFloat {
        DockPanelKind.allCases.map { panelWidth($0) }.max() ?? panelContentWidth
    }
    static func panelHeight(_ kind: DockPanelKind) -> CGFloat {
        switch kind {
        case .cpu: return 368
        case .memory: return 366
        case .network: return 398
        case .disk: return 300
        case .io: return 360
        case .battery: return 220
        case .glm: return 330
        case .java: return 420
        case .processes: return 440
        case .note: return 520
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
    /// 当前该探出的卡。nil 时解除"用户已经看过"的抑制。
    private var attentionKind: DockPanelKind?
    /// 用户从探出的卡走进来看过之后,这次异常不再反复探出,直到条件解除。
    private var peekSuppressed = false
    /// 探出的瞬间面板会变大,可能正好盖住鼠标而误触发 mouseEntered。
    /// 这一小段时间内不把 peek 升级成整列扇形。
    private var suppressFanPromotionUntil = Date.distantPast
    /// 按下贴边内容后,直到松手都不因 tracking 误报去展开或收起。
    private var dragTracking = false
    private var dragDidMove = false
    private var dragAnchorX: CGFloat?
    private var dragAnchorY: CGFloat?
    private var dragAnchorOffset: CGFloat?
    private var resizeCursorPushed = false
    /// 拖完松手那一下不算点击,避免卡片或齿轮跟着被点开。
    private var ignoreClickUntil = Date.distantPast

    weak var manager: EdgeDockManager?

    /// 永久展开开启时,静止态就是 .fan——卡片常驻,hover 只在收起时有意义。
    private var restingState: EdgeDockState { CardSettings.shared.alwaysShown ? .fan : .rest }

    /// 没人看的时候该停在哪:永久展开是扇形,有异常且用户还没看过则探出那一张,否则小圆点。
    private var quietState: EdgeDockState {
        if restingState == .fan { return .fan }
        if let kind = attentionKind, !peekSuppressed, EdgeDockCards.cards.contains(kind) {
            return .peek(kind)
        }
        return .rest
    }

    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.model = EdgeDockModel(edge: CardSettings.shared.dockEdge)
        super.init()

        if let vis = screen?.visibleFrame {
            model.verticalOffset = clampedVerticalOffset(visibleHeight: vis.height)
        }

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
        case .peek where restingState == .fan:
            setState(.fan)
        case .fan where restingState == .rest:
            if hotZone.contains(NSEvent.mouseLocation) { startIdleWatch() }
            else { setState(quietState) }
        default:
            break
        }
    }

    /// 采样侧判定该探出(或收回)哪张卡。扇形和详情开着时不打断。
    func applyAttention(_ kind: DockPanelKind?) {
        if kind == nil { peekSuppressed = false }
        attentionKind = kind
        guard restingState != .fan else { return }
        switch model.state {
        case .rest, .peek:
            let target = quietState
            guard model.state != target else { return }
            if target.peekKind != nil {
                suppressFanPromotionUntil = Date().addingTimeInterval(0.45)
            }
            setState(target)
        default:
            break
        }
    }

    /// 切换停靠边缘:先收回静止态,再换向重排(SwiftUI 侧随 model.edge 换向)。
    func applyEdge(_ edge: DockEdge) {
        guard edge != model.edge else { return }
        model.hoveredCard = nil
        setState(quietState)
        model.edge = edge
        layout()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        idleTimer?.invalidate()
        popResizeCursor()
        panel.orderOut(nil)
    }

    // MARK: Layout

    func layout() { layout(for: model.state) }

    func layout(for state: EdgeDockState) {
        guard let screen else { return }
        let full = screen.frame
        let vis = screen.visibleFrame
        let offset = clampedVerticalOffset(visibleHeight: vis.height)
        if model.verticalOffset != offset {
            model.verticalOffset = offset
        }

        let frame: NSRect
        switch model.edge {
        case .right:
            frame = verticalFrame(state, full: full, vis: vis, fromRight: true, offset: offset)
        case .left:
            frame = verticalFrame(state, full: full, vis: vis, fromRight: false, offset: offset)
        case .bottomRight:
            frame = bottomFrame(state, full: full, fromRight: true)
        }
        // display:false——不在点击处理里强制同步重绘(那一帧本来就被
        // resize + SwiftUI 重排占满,同步绘制正是点击瞬间掉帧的来源)。
        // 内容下一拍自然重绘,两帧的发布延迟保证 resize 先落地。
        // 拖动时扇形窗口尺寸不变,只改 SwiftUI 里的偏移;相同 frame 不再 setFrame。
        if framesDiffer(panel.frame, frame) {
            panel.setFrame(frame, display: false, animate: false)
        }
    }

    /// 左右缘小圆点离可见区底边的距离。偏好比这块屏高时只夹取显示,不改存储值。
    private func clampedVerticalOffset(visibleHeight: CGFloat) -> CGFloat {
        let limit = max(0, visibleHeight - DockGeom.pillHeight)
        let raw = CardSettings.shared.dockVerticalOffset
        guard raw.isFinite else { return min(DockGeom.pillBottomMargin, limit) }
        return min(max(0, raw), limit).rounded()
    }

    private func framesDiffer(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) > 0.5
            || abs(a.origin.y - b.origin.y) > 0.5
            || abs(a.size.width - b.size.width) > 0.5
            || abs(a.size.height - b.size.height) > 0.5
    }

    /// 左右两缘:面板是一条贴边窄条,只有停靠方向不同。高度锚在用户拖好的位置。
    private func verticalFrame(_ state: EdgeDockState, full: NSRect, vis: NSRect,
                               fromRight: Bool, offset: CGFloat) -> NSRect {
        switch state {
        case .rest:
            // 静止的面板本身就是贴边检测条:pill 画在边缘,其余部分透明、可穿透。
            let x = fromRight ? full.maxX - DockGeom.pillWidth : full.minX
            return NSRect(x: x, y: round(vis.minY + offset),
                          width: DockGeom.pillWidth, height: DockGeom.pillHeight)
        case .peek:
            // 与扇形同一套原点(y = 可见区底边),pill 的屏幕位置公式才对得上,
            // 探出和收回时小圆点不挪窝。圆点靠近底边时高度只够一张卡;
            // 拖高之后把窗口加高,否则圆点会跳到探出窗口的顶上。
            return peekFrame(full: full, vis: vis, fromRight: fromRight, vertical: true,
                             offset: offset)
        case .fan:
            // fan 与 expanded 同尺寸:首次拉出面板时窗口零 resize,状态可以
            // 同步发布(没有 resize/挂载的同拍竞争)。多出来的区域透明且点击穿透。
            let w = DockGeom.tabWidth + DockGeom.maxPanelWidth
            return NSRect(x: fromRight ? full.maxX - w : full.minX,
                          y: vis.minY, width: w, height: vis.height)
        case .expanded:
            // 展开窗口恒取最大面板(进程)的尺寸:换面板时窗口完全不动,
            // 旧面板不会被瞬间变大的窗口"拽"到新位置再开始动画(两步运动
            // 就是切换时的抖动)。恒定窗口多出来的区域是透明的,点击穿透。
            let w = DockGeom.tabWidth + DockGeom.maxPanelWidth
            return NSRect(x: fromRight ? full.maxX - w : full.minX,
                          y: vis.minY, width: w, height: vis.height)
        }
    }

    /// 下缘:pill/卡片横躺成一排,面板锚在对应的下角向对侧、向上生长。
    /// 贴屏幕真正的底边(而不是 visibleFrame 底边)——盖在 Dock 区域上。
    private func bottomFrame(_ state: EdgeDockState, full: NSRect, fromRight: Bool) -> NSRect {
        switch state {
        case .rest:
            let size = DockGeom.horizontalPillSize
            // rest 面板 = pill 内容 + 内边距,恰好装下。子视图一旦溢出面板,
            // SwiftUI 的对齐落点和对得齐时不同,pill 会先偏一点再弹回。
            let w = size.width + DockGeom.bottomCornerInset + 1
            let h = size.height
            let x = fromRight ? full.maxX - w : full.minX
            return NSRect(x: x, y: full.minY, width: w, height: h)
        case .peek:
            // 下角不读 vis:探出的卡贴屏幕真底边,和静止 pill 同一个 y。
            return peekFrame(full: full, vis: full, fromRight: fromRight, vertical: false)
        case .fan:
            // 与展开态同尺寸(理由同 verticalFrame 的 .fan 注释)。
            let w = DockGeom.tabWidth + DockGeom.maxPanelWidth
            let h = DockGeom.tabWidth + DockGeom.panelHeight(.processes)
            let x = fromRight ? full.maxX - w : full.minX
            return NSRect(x: x, y: full.minY, width: w, height: h)
        case .expanded:
            // 与左右缘同理:展开窗口恒取最大面板的尺寸。
            let w = DockGeom.tabWidth + DockGeom.maxPanelWidth
            let h = DockGeom.tabWidth + DockGeom.panelHeight(.processes)
            let x = fromRight ? full.maxX - w : full.minX
            return NSRect(x: x, y: full.minY, width: w, height: h)
        }
    }

    /// 只装下一张探出的卡。垂直时贴可见区底边,下角时贴屏幕真底边,和静止 pill 对齐。
    private func peekFrame(full: NSRect, vis: NSRect, fromRight: Bool, vertical: Bool,
                           offset: CGFloat = 0) -> NSRect {
        if vertical {
            let w = DockGeom.tabWidth + DockGeom.bleed + 20
            let needed = offset + DockGeom.pillHeight + 36
            let h = min(vis.height, max(360, needed))
            let x = fromRight ? full.maxX - w : full.minX
            return NSRect(x: x, y: vis.minY, width: w, height: h)
        }
        let pill = DockGeom.horizontalPillSize
        let w = max(pill.width + DockGeom.bottomCornerInset + 1,
                    DockGeom.tabWidth + DockGeom.cogSize + DockGeom.cogGap
                        + DockGeom.bottomCornerInset + 28)
        let h: CGFloat = 240
        let x = fromRight ? full.maxX - w : full.minX
        return NSRect(x: x, y: full.minY, width: w, height: h)
    }

    // MARK: 左右缘拖动

    /// 点在左右缘的小圆点或卡片上时才开始拖。空白穿透区和详情面板主体不算。
    func prepareVerticalDrag(at screenPoint: NSPoint) -> Bool {
        guard acceptsVerticalDrag(at: screenPoint), let screen else { return false }
        dragTracking = true
        dragDidMove = false
        dragAnchorX = screenPoint.x
        dragAnchorY = screenPoint.y
        dragAnchorOffset = clampedVerticalOffset(visibleHeight: screen.visibleFrame.height)
        exitWork?.cancel()
        exitWork = nil
        return true
    }

    func updateVerticalDrag(to screenPoint: NSPoint) {
        guard dragTracking, let y0 = dragAnchorY, let x0 = dragAnchorX,
              let origin = dragAnchorOffset else { return }
        if !dragDidMove {
            let dy = screenPoint.y - y0
            let dx = screenPoint.x - x0
            guard abs(dy) >= 4, abs(dy) > abs(dx) else { return }
            dragDidMove = true
            pushResizeCursor()
            model.hoveredCard = nil
        }
        guard let screen else { return }
        let limit = max(0, screen.visibleFrame.height - DockGeom.pillHeight)
        let proposed = min(max(0, origin + screenPoint.y - y0), limit).rounded()
        guard proposed != CardSettings.shared.dockVerticalOffset else { return }
        CardSettings.shared.dockVerticalOffset = proposed
        manager?.layoutAllDocks()
    }

    func endVerticalDrag() {
        guard dragTracking else { return }
        let moved = dragDidMove
        dragTracking = false
        dragDidMove = false
        dragAnchorX = nil
        dragAnchorY = nil
        dragAnchorOffset = nil
        popResizeCursor()
        noteActivity()
        if moved {
            ignoreClickUntil = Date().addingTimeInterval(0.25)
        }
        // 按下期间屏蔽了 pointerExited。松手时指针已经离开贴边,就收回去。
        if model.state == .fan, restingState != .fan,
           !hotZone.contains(NSEvent.mouseLocation) {
            setState(quietState)
        }
    }

    /// 拖完瞬间的松手。卡片、齿轮、关闭按钮都来问一次。
    func consumeDragClick() -> Bool {
        Date() < ignoreClickUntil
    }

    private func acceptsVerticalDrag(at screenPoint: NSPoint) -> Bool {
        guard !model.edge.isBottom, let screen else { return false }
        guard screen.frame.contains(screenPoint) else { return false }
        guard edgeStrip(full: screen.frame).contains(screenPoint) else { return false }
        return dockContentHit(at: screenPoint)
    }

    /// 贴屏幕左右缘的一条窄带,盖住小圆点和卡片,不盖住详情面板主体。
    private func edgeStrip(full: NSRect) -> NSRect {
        let width = DockGeom.fanWidth + 16
        switch model.edge {
        case .right:
            return NSRect(x: full.maxX - width, y: full.minY, width: width, height: full.height)
        case .left:
            return NSRect(x: full.minX, y: full.minY, width: width, height: full.height)
        case .bottomRight:
            return .zero
        }
    }

    /// 透明区域的 hitTest 是 nil,和点击穿透同一套判断。
    private func dockContentHit(at screenPoint: NSPoint) -> Bool {
        guard panel.frame.contains(screenPoint) else { return false }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        guard let superview = container.superview else { return true }
        let superPoint = superview.convert(windowPoint, from: nil)
        return container.hitTest(superPoint) != nil
    }

    private func pushResizeCursor() {
        guard !resizeCursorPushed else { return }
        NSCursor.resizeUpDown.push()
        resizeCursorPushed = true
    }

    private func popResizeCursor() {
        guard resizeCursorPushed else { return }
        NSCursor.pop()
        resizeCursorPushed = false
    }

    // MARK: Transitions

    private func setState(_ new: EdgeDockState) {
        let old = model.state
        guard old != new else { return }
        // 退场已经在播,再来一次会把收尾定时器取消掉,卡片就停在半路。
        if new == .rest, model.closing, old.expandedKind == nil { return }
        shrinkWork?.cancel(); shrinkWork = nil

        if new.rank >= old.rank {
            // 窗口 frame 只由状态档位决定,且 fan 与 expanded 同尺寸:
            // 首次拉出和换面板都不再发生窗口 resize,面板挂载没有与 resize
            // 的同拍竞争,状态同步发布——点击下一拍就动起来,没有死区。
            // (旧方案"resize 先渲染两帧再发布"的整个延迟机制已随之删除。)
            layout(for: new)
            if new == .fan || new.peekKind != nil {
                model.state = new
            } else {
                // 临界阻尼(1.0):同样快,但没有过冲回弹——欠阻尼弹簧
                // 收尾要过冲 1~2 次,在大面板上就是肉眼可见的抖动。
                withAnimation(.spring(response: 0.28, dampingFraction: 1.0)) {
                    self.model.state = new
                }
            }
        } else {
            // 扇形退回小圆点:不要包一层 withAnimation。入场是每张卡自己的
            // 延迟弹簧,退场必须走同一条路径才会按相反顺序收回。外层动画会把
            // 延迟吃掉,看起来就不是入场的倒放。
            let cardsOnly = new == .rest && old.expandedKind == nil
            if cardsOnly {
                // 先只翻 closing:卡片还在树上,按相反顺序收回。播完再落到 .rest 并缩窗。
                if !model.closing {
                    model.closing = true
                    let work = DispatchWorkItem { [weak self] in self?.finishClose() }
                    shrinkWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + DockGeom.fanExitDuration, execute: work)
                }
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    self.model.state = new
                }
                let work = DispatchWorkItem { [weak self] in self?.layout() }
                shrinkWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            }
        }

        if new.expandedKind != nil {
            installKeyMonitor(); installOutsideMonitor()
        } else {
            removeKeyMonitor(); removeOutsideMonitor()
        }
        // 扇形和详情才需要"无人看管自动收起"。探出的卡是故意留着的,不收。
        switch new {
        case .fan where restingState != .fan:
            startIdleWatch()
        case .expanded:
            startIdleWatch()
        default:
            stopIdleWatch()
        }
    }

    /// 退场播完:这时卡片已经回到贴边,再缩成小圆点。
    private func finishClose() {
        guard model.closing else { return }
        // 先落到 .rest 再清 closing。顺序反了的话,中间一帧会把卡片重新判成展开,闪一下。
        model.state = .rest
        model.closing = false
        layout()
        stopIdleWatch()
        removeKeyMonitor()
        removeOutsideMonitor()
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
            if self.dragTracking {
                self.noteActivity()
                return
            }
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
        case .bottomRight:
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: depth)
        }
    }

    func pointerEntered() {
        if dragTracking { return }
        noteActivity()
        exitWork?.cancel(); exitWork = nil
        // 退场时面板还是全尺寸,布局一变就会误报「鼠标进来」。
        // 只有光标真的回到卡片热区,才取消收回。
        let backOnCards = hotZone.contains(NSEvent.mouseLocation)
        if model.closing && !backOnCards {
            // 继续收。
        } else {
            shrinkWork?.cancel(); shrinkWork = nil
            if model.closing {
                model.closing = false
                if model.state == .fan { startIdleWatch() }
            }
        }
        // 探出面板变大时可能刚好盖住光标,这一小段不升级成整列。
        if Date() < suppressFanPromotionUntil { return }
        switch model.state {
        case .rest:
            manager?.dockDidActivate(self)
            setState(.fan)
        case .peek:
            peekSuppressed = true
            manager?.dockDidActivate(self)
            setState(.fan)
        default:
            layout()
        }
    }

    func pointerExited() {
        if dragTracking { return }
        // 永久展开模式下指针离开不收起;拉出的详情保持打开,直到 Esc/外部点击。
        guard model.state == .fan, restingState != .fan else { return }
        // resize 时 tracking area 会误报,延迟确认指针确实离开了。
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .fan else { return }
            if !self.hotZone.contains(NSEvent.mouseLocation) {
                self.setState(self.quietState)
            }
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func toggle(_ kind: DockPanelKind) {
        if consumeDragClick() { return }
        noteActivity()
        if model.state.expandedKind == kind { collapse() } else { expand(kind) }
    }

    func expand(_ kind: DockPanelKind) {
        noteActivity()
        manager?.dockDidActivate(self)
        setState(.expanded(kind))
        // 激活与 key 化移出点击帧:首次激活要走窗口服务往返,同步做会让
        // 动画的第一帧迟到,正是"首次点开顿一下"的来源之一。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate()
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    /// 关闭详情 → 退回扇形,卡片留在原位;只有完全离开才收起。
    func collapse() {
        if model.state.expandedKind != nil {
            setState(.fan)
            NSApp.deactivate()
        } else {
            setState(quietState)
        }
    }

    /// 整个收回到静止态(永久展开时即保持扇形,有未看过的异常则探出那一张)。
    func dismiss() {
        let wasExpanded = model.state.expandedKind != nil
        setState(quietState)
        if wasExpanded { NSApp.deactivate() }
    }

    func collapseToRest() { setState(quietState) }

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
    /// 律动不占卡片,每块屏的左下角一块独立频谱。
    private var pulseCorners: [CGDirectDisplayID: PulseCornerController] = [:]
    private var bag = Set<AnyCancellable>()
    private var dragMonitors: [Any] = []
    private var draggingDisplayID: CGDirectDisplayID?

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
        MonitorStore.shared.$attention
            .receive(on: RunLoop.main)
            .sink { [weak self] kind in
                self?.docks.values.forEach { $0.applyAttention(kind) }
            }
            .store(in: &bag)
        CardSettings.shared.$pulseEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] shown in
                self?.pulseCorners.values.forEach { $0.setShown(shown) }
            }
            .store(in: &bag)
        rebuild()
        installDragMonitors()
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
        for id in Array(pulseCorners.keys) where !ids.contains(id) {
            pulseCorners.removeValue(forKey: id)
        }
        for id in ids where docks[id] == nil {
            let dock = EdgeDockController(displayID: id)
            dock.manager = self
            dock.applyAttention(MonitorStore.shared.attention)
            docks[id] = dock
        }
        let pulseOn = CardSettings.shared.pulseEnabled
        for id in ids where pulseCorners[id] == nil {
            let corner = PulseCornerController(displayID: id)
            corner.setShown(pulseOn)
            pulseCorners[id] = corner
        }
        docks.values.forEach { $0.layout() }
        pulseCorners.values.forEach { $0.layout() }
    }

    func layoutAllDocks() {
        docks.values.forEach { $0.layout() }
    }

    /// 左右缘按下后上下拖。本应用收到的走 local,点在别的应用上时走 global,两边不会同时来。
    private func installDragMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.routeVerticalDrag(event)
            return event
        }) {
            dragMonitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.routeVerticalDrag(event)
        }) {
            dragMonitors.append(monitor)
        }
    }

    private func screenPoint(from event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func routeVerticalDrag(_ event: NSEvent) {
        let point = screenPoint(from: event)
        switch event.type {
        case .leftMouseDown:
            if let draggingDisplayID {
                docks[draggingDisplayID]?.endVerticalDrag()
            }
            draggingDisplayID = docks.first { _, dock in
                dock.prepareVerticalDrag(at: point)
            }?.key
        case .leftMouseDragged:
            guard let draggingDisplayID, let dock = docks[draggingDisplayID] else { return }
            dock.updateVerticalDrag(to: point)
        case .leftMouseUp:
            let id = draggingDisplayID
            draggingDisplayID = nil
            if let id { docks[id]?.endVerticalDrag() }
        default:
            break
        }
    }

    deinit {
        dragMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    /// 同一时间只展开一个——指针进入哪个屏就收起其他的。
    func dockDidActivate(_ active: EdgeDockController) {
        for d in docks.values where d !== active { d.collapseToRest() }
    }
}

// MARK: - 左下角律动

/// 不参与贴边卡片。透明、不吃点击,条从屏幕真底边往上长。
final class PulseCornerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

final class PulseCornerController {
    let displayID: CGDirectDisplayID
    private let panel = PulseCornerPanel()

    /// 比设置齿轮(24pt)略高一档,条再高也不超出这块玻璃。
    private static let size = CGSize(width: 200, height: 40)

    private var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let host = EdgeDockHostingView(rootView: PulseCornerView())
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        layout()
    }

    deinit { panel.orderOut(nil) }

    func layout() {
        guard let screen else { return }
        let full = screen.frame
        let size = Self.size
        // 贴屏幕真底边、靠左,盖在 Dock 区域上,和右下角贴边同一条底边。
        panel.setFrame(NSRect(x: full.minX + 8,
                              y: full.minY,
                              width: size.width,
                              height: size.height),
                       display: false, animate: false)
    }

    func setShown(_ shown: Bool) {
        if shown {
            layout()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
