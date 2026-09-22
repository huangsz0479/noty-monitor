import SwiftUI
import AppKit

// MARK: - 调色板(noty 原版配色)

/// noty 的纸色三件套:纸面 / 色条 / 纸上墨色。
struct MetricColor {
    let paper: Color
    let dash: Color
    let ink: Color
}

private func hex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255,
          green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255)
}

extension DockPanelKind {
    /// 每张指标卡一个专属色,取自 noty 的便签调色板。
    var palette: MetricColor {
        switch self {
        case .cpu:       return MetricColor(paper: hex(0xBEDDFA), dash: hex(0x2280D6), ink: hex(0x13293A))  // Sky
        case .memory:    return MetricColor(paper: hex(0xB4E8D0), dash: hex(0x0E9B6E), ink: hex(0x0F2E23))  // Mint
        case .network:   return MetricColor(paper: hex(0xFBCFA6), dash: hex(0xE2762A), ink: hex(0x422413))  // Peach
        case .disk:      return MetricColor(paper: hex(0xE3D3B4), dash: hex(0xA37B3C), ink: hex(0x372C18))  // Sand
        case .io:        return MetricColor(paper: hex(0xC9D3DE), dash: hex(0x4A6B8A), ink: hex(0x18242F))  // Slate
        case .battery:   return MetricColor(paper: hex(0xFCE795), dash: hex(0xE0AD08), ink: hex(0x3A3008))  // Lemon
        case .glm:       return MetricColor(paper: hex(0xF7C6CE), dash: hex(0xD8495B), ink: hex(0x3B161C))  // Rose
        case .java:      return MetricColor(paper: hex(0xCDB492), dash: hex(0x7B4B23), ink: hex(0x2A1A0C))  // Mocha
        case .processes: return MetricColor(paper: hex(0xD9C7FA), dash: hex(0x7C4DEE), ink: hex(0x2A1B44))  // Lilac
        }
    }
}

// MARK: - Root

struct EdgeDockRootView: View {
    @ObservedObject var dock: EdgeDockModel
    unowned let controller: EdgeDockController
    @ObservedObject var store = MonitorStore.shared
    @ObservedObject var settings = CardSettings.shared

    private var edge: DockEdge { dock.edge }
    /// 卡片收回途中先别亮;等到最后一张基本到位再亮。展开时必须灭掉。
    @State private var pillAfterCards = false
    private var pillShown: Bool {
        if dock.state == .rest { return true }
        return dock.closing && pillAfterCards
    }

    private var rootAlignment: Alignment {
        switch edge {
        case .right:       return .topTrailing
        case .left:        return .topLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    var body: some View {
        // 尺寸取自实时布局:面板 resize 时 AppKit 先按新尺寸排布旧视图树,
        // 缓存在 model 里的高度会有一帧是过期的。
        GeometryReader { geo in
            let h = max(1, geo.size.height)
            let w = max(1, geo.size.width)

            ZStack(alignment: rootAlignment) {

                if dock.state != .rest {
                    MetricFanColumn(dock: dock, controller: controller, store: store)
                        .transition(.identity)
                        .padding(fanPadding(panelHeight: h, panelWidth: w))
                }

                MonitorPillView(store: store, edge: edge)
                    .padding(pillPadding(panelHeight: h, panelWidth: w))
                    .transaction { $0.animation = nil }
                    .opacity(pillShown ? 1 : 0)
                    // 展开时立刻灭掉。淡出要 0.12s,第一张卡已经从圆点上冒出来,看起来就是闪。
                    .animation(pillShown ? .easeOut(duration: 0.1) : nil, value: pillShown)

                // 最后声明,盖住卡片列,贴屏幕边缘。
                if let kind = dock.state.expandedKind {
                    MetricPanelView(kind: kind, store: store, edge: edge,
                                    onClose: {
                                        if controller.consumeDragClick() { return }
                                        controller.collapse()
                                    })
                        .padding(panelPadding(kind: kind, panelHeight: h, panelWidth: w))
                        .transition(.modifier(active: PanelPull(hidden: true, edge: edge),
                                               identity: PanelPull(hidden: false, edge: edge)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rootAlignment)
        }
        .onChange(of: dock.closing) { _, closing in
            if closing {
                // 上一轮留下的标记会让小圆点在第二次退场一开始就亮。先清掉,再等进程卡落定。
                pillAfterCards = false
                DispatchQueue.main.asyncAfter(deadline: .now() + DockGeom.pillRevealDelay) {
                    if dock.closing || dock.state == .rest { pillAfterCards = true }
                }
            } else if dock.state != .rest {
                pillAfterCards = false
            }
        }
    }

    /// 面板生长时 pill 停在屏幕原位不动:各边缘用各自的边距公式锁位。
    private func pillPadding(panelHeight ph: CGFloat, panelWidth pw: CGFloat) -> EdgeInsets {
        switch edge {
        case .right:
            return EdgeInsets(top: pillTop(panelHeight: ph), leading: 0, bottom: 0, trailing: 1)
        case .left:
            return EdgeInsets(top: pillTop(panelHeight: ph), leading: 1, bottom: 0, trailing: 0)
        case .bottomRight:
            // 下角:rest/fan 面板共享同一条角落边,pill 恒贴角即可全程不挪位。
            // 不能用随面板宽度变化的公式——收起动画的 0.45s 里面板还是
            // 全宽,会把 pill 算到卡片排那端,弹回角落时肉眼可见地跳一下。
            return EdgeInsets(top: 0, leading: 0, bottom: 0,
                              trailing: DockGeom.bottomCornerInset + 1)
        }
    }

    private func fanPadding(panelHeight ph: CGFloat, panelWidth pw: CGFloat) -> EdgeInsets {
        switch edge {
        case .right, .left:
            return EdgeInsets(top: fanTop(panelHeight: ph), leading: 0, bottom: 0, trailing: 0)
        case .bottomRight:
            // 卡片一排贴着右下角,底边与屏幕底边齐平。
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: DockGeom.bottomCornerInset)
        }
    }

    /// 详情面板的定位:左右缘垂直居中于卡片列,下缘从卡片排上方顶出
    /// (贴边卡片条的留位由面板内部自己处理)。
    private func panelPadding(kind: DockPanelKind, panelHeight ph: CGFloat,
                              panelWidth pw: CGFloat) -> EdgeInsets {
        switch edge {
        case .right, .left:
            return EdgeInsets(top: panelTop(kind: kind, panelHeight: ph), leading: 0,
                              bottom: 0, trailing: 0)
        case .bottomRight:
            return EdgeInsets()
        }
    }

    /// 面板全高、底边贴着可见区底边时,pill 仍落在拖好的高度上:
    /// 顶部偏移 = 面板高 - 底边距 - pill 高。静止窗口本身就是 pill,这个值是 0。
    private func pillTop(panelHeight h: CGFloat) -> CGFloat {
        max(0, h - dock.verticalOffset - DockGeom.pillHeight)
    }

    /// 锚点列高:与 hover 无关。"悬停显示数值"只伸缩被悬停的那张卡本身,
    /// 整列顶端和详情面板的弹出位都用纯标题的列高计算——否则点击后指针
    /// 离开卡片,列高缩回,整列连同面板当场滑一下(肉眼可见的"跳")。
    /// 探出时只排那一张,并且数值算进高度(它一直亮着)。
    private var layoutCards: [DockPanelKind] {
        if let kind = dock.state.peekKind, EdgeDockCards.cards.contains(kind) { return [kind] }
        return EdgeDockCards.cards
    }

    private var anchorStack: CGFloat {
        let values = Dictionary(uniqueKeysWithValues: layoutCards.map {
            ($0, CardMetrics.value(for: $0, store: store))
        })
        // 探出的卡数值常显,高度按带数值算;其余时候仍按纯标题,避免悬停把整列顶走。
        let titleOnly = CardMetrics.displayValues(
            values, hovered: nil,
            hoverReveals: settings.hoverRevealsValue && dock.state.peekKind == nil)
        return CardMetrics.totalHeight(values: titleOnly, cards: layoutCards)
            + DockGeom.cogGap + DockGeom.cogSize
    }

    /// 扇形以 pill 中心为轴向上展开,但不跑出屏幕。
    private func fanTop(panelHeight h: CGFloat) -> CGFloat {
        let pillCenter = h - dock.verticalOffset - DockGeom.pillHeight / 2
        return min(max(12, pillCenter - anchorStack / 2), max(12, h - anchorStack - 12))
    }

    /// 详情面板固定在整列卡片的旁边垂直居中——所有卡共用一个弹出位,
    /// 稳定可预期,不再跟着被点的卡片上下飞。
    private func panelTop(kind: DockPanelKind, panelHeight h: CGFloat) -> CGFloat {
        let panelH = DockGeom.panelHeight(kind)
        let ideal = fanTop(panelHeight: h) + (anchorStack - panelH) / 2
        return min(max(10, ideal), max(10, h - panelH - 10))
    }
}

// MARK: - Pill(静止时贴边的小圆点)

struct MonitorPillView: View {
    @ObservedObject var store: MonitorStore
    var edge: DockEdge = .right
    /// 异常那根彩条的呼吸。视图一直在树上,动画只开一次。
    @State private var pulse = false

    var body: some View {
        pillContent
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .frame(width: edge.isBottom ? DockGeom.horizontalPillSize.width : DockGeom.pillWidth,
                   height: edge.isBottom ? DockGeom.horizontalPillSize.height : nil)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.ultraThinMaterial)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 6,
                            x: edge == .left ? 2 : -2, y: 1)
            )
    }

    /// 左右缘彩条竖叠,下缘横躺并排。
    @ViewBuilder
    private var pillContent: some View {
        if edge.isBottom {
            HStack(spacing: DockGeom.dashGap) {
                ForEach(EdgeDockCards.cards) { kind in
                    dash(kind)
                }
            }
            .padding(.horizontal, DockGeom.pillPad)
        } else {
            VStack(spacing: DockGeom.dashGap) {
                ForEach(EdgeDockCards.cards) { kind in
                    dash(kind)
                }
            }
            .padding(.vertical, DockGeom.pillPad)
        }
    }

    /// 用量越高色越实;被点名的那根在两档之间呼吸,直到卡片自己探出来。
    private func dash(_ kind: DockPanelKind) -> some View {
        let alerting = store.attention == kind
        let level = store.dashLevels.level(for: kind)
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(kind.palette.dash)
            .frame(width: DockGeom.dashWidth, height: DockGeom.dashHeight)
            .opacity(alerting ? (pulse ? 1 : 0.38) : (0.32 + 0.68 * level))
            .animation(.easeInOut(duration: 0.35), value: level)
    }
}

// MARK: - Fan(扇形展开的指标卡)

struct MetricFanColumn: View {
    @ObservedObject var dock: EdgeDockModel
    unowned let controller: EdgeDockController
    @ObservedObject var store: MonitorStore
    @ObservedObject var settings = CardSettings.shared

    @State private var appeared = false

    private var isRevealed: Bool { dock.state != .rest && appeared && !dock.closing }

    /// 探出时扇形里只留那一张。
    private var shownCards: [DockPanelKind] {
        if let kind = dock.state.peekKind, EdgeDockCards.cards.contains(kind) { return [kind] }
        return EdgeDockCards.cards
    }

    private var valuesById: [DockPanelKind: String] {
        Dictionary(uniqueKeysWithValues: shownCards.map {
            ($0, CardMetrics.value(for: $0, store: store))
        })
    }

    /// 卡面上实际显示的数值:由"悬停显示数值"设置决定(hover 模式下只有
    /// 被悬停的卡带数值,其余为空 → 只显示名称、按标题高度布局)。
    /// 详情面板开着时其卡片"钉住"数值:指针从卡片移进面板会触发 hover
    /// 退出,不钉住的话这张卡当场缩回、下方卡片集体上移,看起来就是抖动。
    private var displayValues: [DockPanelKind: String] {
        CardMetrics.displayValues(valuesById, hovered: dock.hoveredCard,
                                  hoverReveals: settings.hoverRevealsValue,
                                  pinned: dock.state.expandedKind ?? dock.state.peekKind)
    }

    private var layouts: [(kind: DockPanelKind, y: CGFloat, height: CGFloat)] {
        CardMetrics.layouts(values: displayValues, cards: shownCards)
    }

    private var totalHeight: CGFloat {
        CardMetrics.totalHeight(values: displayValues, cards: shownCards)
    }

    /// 下缘整排的总宽(卡片宽度恒定,叠压量相同)。
    private var rowWidth: CGFloat {
        let n = CGFloat(shownCards.count)
        return n * DockGeom.tabWidth - max(0, n - 1) * DockGeom.tabLap
    }

    /// 数值显隐完全由 displayValues 决定;click 仍开详情面板,不变。
    private func tab(item: (kind: DockPanelKind, y: CGFloat, height: CGFloat), index: Int) -> some View {
        MetricTab(title: item.kind.rawValue,
                  value: displayValues[item.kind] ?? "",
                  palette: item.kind.palette,
                  isOpen: dock.state.expandedKind == item.kind,
                  edge: dock.edge,
                  height: item.height,
                  strip: item.height,
                  action: { controller.toggle(item.kind) })
    }

    var body: some View {
        Group {
            switch dock.edge {
            case .right, .left:
                verticalColumn
            case .bottomRight:
                bottomColumn(fromRight: true)
            }
        }
        .onAppear {
            DispatchQueue.main.async { appeared = true }
        }
        .onChange(of: dock.state) { _, newState in
            if newState == .rest {
                appeared = false
                dock.hoveredCard = nil   // 收起后下次展开不带旧的 hover 态
            }
        }
    }

    /// 左右缘:卡片竖排叠压,显式 y 偏移定位(不用 VStack 负间距——
    /// 它对带 rotationEffect 的不定高子视图会算错总高)。
    private var verticalColumn: some View {
        ZStack(alignment: dock.edge == .left ? .topLeading : .topTrailing) {
            ForEach(Array(layouts.enumerated()), id: \.element.kind.id) { idx, item in
                placedTab(item: item, index: idx)
                    .padding(.top, item.y)
            }

            CogButton { openSettings() }
                .padding(.top, totalHeight + 4)
                .staged(index: shownCards.count,
                        total: shownCards.count + 1,
                        revealed: isRevealed, edge: dock.edge)

            // dock 悬挂其上的虚线,就在屏幕边缘上。
            EdgeLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(width: 1, height: totalHeight + DockGeom.cogSize + 22)
                .padding(dock.edge == .left ? .leading : .trailing, 3)
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    /// 下角:卡片横向并排,一起站在底边上。注意定位 padding 要与对齐方向
    /// 相反侧为空——bottomTrailing 下 leading padding 会被透明占位吃掉,
    /// 卡片全叠在一处(bottomLeading 镜像同理)。齿轮在远离角落的一端。
    private func bottomColumn(fromRight: Bool) -> some View {
        ZStack(alignment: fromRight ? .bottomTrailing : .bottomLeading) {
            ForEach(Array(layouts.enumerated()), id: \.element.kind.id) { idx, item in
                placedTab(item: item, index: idx)
                    .padding(fromRight ? .trailing : .leading,
                             CGFloat(shownCards.count - 1 - idx)
                                 * (DockGeom.tabWidth - DockGeom.tabLap))
            }

            CogButton { openSettings() }
                .padding(fromRight ? .trailing : .leading, rowWidth + 4)
                .staged(index: shownCards.count,
                        total: shownCards.count + 1,
                        revealed: isRevealed, edge: dock.edge)

            EdgeLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(width: rowWidth + DockGeom.cogSize + 22, height: 1)
                .padding(.bottom, 0)
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private func openSettings() {
        if controller.consumeDragClick() { return }
        SettingsWindow.shared.show()
    }

    /// onHover 必须贴在卡片本体上(定位 padding 之前):padding 的透明
    /// 区域也是命中区,挂外面会串卡。
    private func placedTab(item: (kind: DockPanelKind, y: CGFloat, height: CGFloat),
                           index: Int) -> some View {
        tab(item: item, index: index)
            .animation(.snappy(duration: 0.3), value: item.height)
            .onHover { entering in
                // 只清掉自己的 hover:跨卡移动时 exit 事件可能晚于下一张的 enter。
                if entering {
                    dock.hoveredCard = item.kind
                } else if dock.hoveredCard == item.kind {
                    dock.hoveredCard = nil
                }
            }
            .staged(index: index, total: shownCards.count + 1,
                    revealed: isRevealed, edge: dock.edge)
    }
}

/// 数值文本与卡片高度的权威来源:高度由 NSHostingView 布局引擎实测
/// (fittingSize),不用手写公式——公式永远追不上 SwiftUI 的真实排版。
enum CardMetrics {
    private static var cache: [String: CGFloat] = [:]
    private static var pending: Set<String> = []

    /// 高度 = 布局引擎实测值(NSHostingView fittingSize)。
    /// 测量绝不能发生在视图更新过程中(会重入 AttributeGraph 直接 abort),
    /// 所以:未命中时先返回估算值,并在下一拍异步实测,完成后 bump tick 重绘。
    static func measuredHeight(title: String, value: String) -> CGFloat {
        let key = "\(title)|\(Self.quantized(value))"
        if let hit = cache[key] { return hit }
        if cache.count > 256 { cache.removeAll() }   // 防御:键空间理论有界,仍兜底封顶
        if !pending.contains(key) {
            pending.insert(key)
            DispatchQueue.main.async {
                defer { pending.remove(key) }
                let label = VerticalMetricLabel(
                    title: title, value: value, strip: nil,
                    palette: MetricColor(paper: .clear, dash: .clear, ink: .clear))
                let host = NSHostingView(rootView: label.frame(width: DockGeom.tabWidth))
                host.frame = NSRect(x: 0, y: 0, width: DockGeom.tabWidth, height: 300)
                host.layoutSubtreeIfNeeded()
                cache[key] = ceil(host.fittingSize.height) + 14   // + 上下 padding(7×2)
                MonitorStore.shared.layoutTick &+= 1
            }
        }
        return estimate(title: title, value: value)
    }

    /// 数字折叠成 0 再作缓存键:数值是等宽字体,折叠后宽度与高度都不变,
    /// 而网速/百分比这类每拍都变的文本不会再产生新键、触发无谓的实测。
    private static func quantized(_ value: String) -> String {
        String(value.map { $0.isNumber ? "0" : $0 })
    }

    /// 实测未落地时的估算(只需大致正确,一拍后即被实测值替换)。
    private static func estimate(title: String, value: String) -> CGFloat {
        let upright = !title.isEmpty && title.allSatisfy(UpRight.isUpright)
        if upright {
            let titleStack = 5 + CGFloat(title.count) * 17 + 12
            return value.isEmpty ? titleStack : titleStack + 23
        }
        // 非直立时卡片高 ≈ 横排文本实测宽。
        let width = VerticalMetricLabel.measure(title)
            + (value.isEmpty ? 0 : 4 + VerticalMetricLabel.measure(value, mono: true))
        return 5 + width + 12
    }

    /// 按显示模式过滤卡面数值:hover 模式只保留被悬停卡的数值(其余按纯标题
    /// 计高、只显示名称),常显模式原样返回。pinned = 详情面板开着的卡片,
    /// 数值常显(与 hover 无关,避免面板打开瞬间卡片列重排抖动)。
    static func displayValues(_ values: [DockPanelKind: String], hovered: DockPanelKind?,
                              hoverReveals: Bool, pinned: DockPanelKind? = nil) -> [DockPanelKind: String] {
        guard hoverReveals else { return values }
        return Dictionary(uniqueKeysWithValues: values.map { kind, value in
            (kind, hovered == kind || pinned == kind ? value : "")
        })
    }

    static func layouts(values: [DockPanelKind: String],
                        cards: [DockPanelKind]? = nil) -> [(kind: DockPanelKind, y: CGFloat, height: CGFloat)] {
        // 未悬停的初始高度整列统一:取"纯标题"最高的那张卡,矮卡补齐到
        // 同一高度(横排旋转的 CPU/I/O 和竖排双字的内存/智谱不再参差);
        // 悬停的卡在统一高度之上长出数值。探出时只排被点名的那一张。
        let order = cards ?? EdgeDockCards.cards
        let restHeight = order
            .map { measuredHeight(title: $0.rawValue, value: "") }
            .max() ?? 0
        var result: [(kind: DockPanelKind, y: CGFloat, height: CGFloat)] = []
        var y: CGFloat = 0
        for kind in order {
            let h = max(measuredHeight(title: kind.rawValue, value: values[kind] ?? ""), restHeight)
            result.append((kind, y, h))
            y += h - DockGeom.tabLap
        }
        return result
    }

    static func totalHeight(values: [DockPanelKind: String],
                            cards: [DockPanelKind]? = nil) -> CGFloat {
        guard let last = layouts(values: values, cards: cards).last else { return 0 }
        return last.y + last.height
    }

    static func value(for kind: DockPanelKind, store: MonitorStore) -> String {
        switch kind {
        case .cpu:
            if let name = store.digest.dominantName {
                return "\(name) \(Int(store.digest.dominantCPU.rounded()))%"
            }
            return store.system.cpuPercent.percentText
        case .memory:
            let ratio = store.system.memoryTotalBytes > 0
                ? Double(store.system.memoryUsedBytes) / Double(store.system.memoryTotalBytes) : 0
            return String(format: "%.0f%%", ratio * 100)
        case .network: return store.net.inPerSec.speedText
        case .disk:
            return store.volumes.first
                .map { String(format: "%.0f%%", $0.usedFraction * 100) } ?? "—"
        case .battery: return store.battery.map { "\(Int($0.percent.rounded()))%" } ?? "—"
        case .io: return store.diskIO.totalBytesPerSec.speedText
        case .glm:
            if let remaining = store.glmPlan?.fiveHour?.remainingPercent {
                return String(format: "%.0f%%", remaining)
            }
            return store.glmPlan?.error != nil ? "!" : "—"
        case .java:
            guard store.digest.javaCount > 0 else { return "—" }
            return store.digest.javaMemoryBytes.memoryText
        case .processes: return String(store.digest.count)
        }
    }
}

// MARK: - Tab(一张指标卡,noty 原版形态)

/// 竖纸条卡:实心彩纸 + 柔和投影。左右缘统一 3° 倾角并向外多画 bleed
/// 防倾斜露缝;下缘不倾斜直立站排。
struct MetricTab: View {
    let title: String
    let value: String
    let palette: MetricColor
    let isOpen: Bool
    let edge: DockEdge
    let height: CGFloat       // 纸面高度 = CardMetrics 实测内容高度
    let strip: CGFloat
    let action: () -> Void

    private var leanDegrees: Double {
        switch edge {
        case .right:  return -DockGeom.leanDegrees
        case .left:   return DockGeom.leanDegrees
        case .bottomRight: return 0
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .top) {
                edgeTabShape(for: edge)
                    .fill(palette.paper)
                    .shadow(color: .black.opacity(isOpen ? 0.32 : 0.22),
                            radius: isOpen ? 10 : 6,
                            x: edge == .left ? 3 : (edge.isBottom ? 0 : -3),
                            y: edge.isBottom ? 4 : 2)
                VerticalMetricLabel(title: title, value: value,
                                    strip: strip, palette: palette)
                    .offset(x: edge == .right ? -DockGeom.bleed / 2
                                : edge == .left ? DockGeom.bleed / 2 : 0)
            }
            .frame(width: DockGeom.tabWidth + (edge.isBottom ? 0 : DockGeom.bleed),
                   height: height, alignment: .top)
            .rotationEffect(.degrees(leanDegrees),
                            anchor: edge == .left ? .leading : .trailing)
            .offset(x: edge.isBottom ? 0
                        : (edge == .left ? -DockGeom.bleed : DockGeom.bleed))
            .frame(width: DockGeom.tabWidth,
                   height: edge.isBottom ? height : nil, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabPressStyle())
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOpen)
        .help(title)
    }
}

/// 竖排标签(noty 两步旋转法):CJK 逐字直立,拉丁/数字整段旋转;
/// 高度完全由 SwiftUI 自然布局决定。
struct VerticalMetricLabel: View {
    let title: String
    let value: String
    let strip: CGFloat?
    let palette: MetricColor

    private var titleIsUpright: Bool { !title.isEmpty && title.allSatisfy(UpRight.isUpright) }

    private var titleRun: Text {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(palette.ink.opacity(0.85))
    }

    private var valueRun: Text {
        Text(value)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundStyle(palette.dash)
    }

    var body: some View {
        VStack(spacing: 3) {
            if titleIsUpright {
                VStack(spacing: 1) {
                    ForEach(Array(title), id: \.self) { ch in
                        Text(String(ch))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(palette.ink.opacity(0.85))
                    }
                }
                if !value.isEmpty {
                    rotated(valueRun, width: Self.measure(value, mono: true))
                }
            } else if value.isEmpty {
                rotated(titleRun, width: Self.measure(title))
            } else {
                rotated(Text("\(titleRun) \(valueRun)"),
                        width: Self.measure(title) + 4 + Self.measure(value, mono: true))
            }
        }
        .modifier(NaturalHeightFrame(strip: strip))
    }

    /// 两步旋转:横排盒(实测宽 × 厚度)→ 旋转 90° → 竖排盒(厚度 × 实测宽)。
    private func rotated(_ label: Text, width w: CGFloat) -> some View {
        label
            .lineLimit(1)
            .fixedSize()
            .frame(width: w, height: 14)
            .rotationEffect(.degrees(90))
            .frame(width: 14, height: w)
    }

    static func measure(_ s: String, mono: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
                        : NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let tracking: CGFloat = mono ? 0 : 1
        return ceil((s as NSString).size(withAttributes: [.font: font]).width
                    + tracking * CGFloat(s.count))
    }
}

/// strip 有值 = 定高外框(渲染);nil = 自然高度(测量)。
private struct NaturalHeightFrame: ViewModifier {
    let strip: CGFloat?
    func body(content: Content) -> some View {
        if let strip {
            // 垂直居中:上下各分到 12pt 内边距(高度 = 内容 + 24)。
            content.frame(width: DockGeom.tabWidth, height: strip, alignment: .center)
        } else {
            content.frame(width: DockGeom.tabWidth)
        }
    }
}

/// CJK/emoji 走直立呈现(取自 noty 的 VerticalLabelLayout 判定,范围精简)。
private enum UpRight {
    static func isUpright(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF,       // CJK 部首、符号与统一表意文字
                 0x3000...0x30FF,       // CJK 标点、假名
                 0xF900...0xFAFF,       // CJK 兼容表意文字
                 0xFF00...0xFFEF,       // 全角形式
                 0x1F000...0x1FAFF:     // emoji
                return true
            default:
                return false
            }
        }
    }
}

/// 列底部的圆形设置齿轮(noty 原版画法):细齿轮 + 材质圆底,悬停放大。
struct CogButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(hovering ? 0.8 : 0.5))
                .frame(width: DockGeom.cogSize, height: DockGeom.cogSize)
                .background(Circle().fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("设置")
    }
}

// MARK: - 详情面板

struct MetricPanelView: View {
    let kind: DockPanelKind
    @ObservedObject var store: MonitorStore
    var edge: DockEdge = .right
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch kind {
            case .cpu:
                chartCard(CPUChart(history: store.cpuHistory, tint: kind.palette.dash, ink: kind.palette.ink).frame(height: 76))
                sectionCaption("负载构成")
                statRows(cpuStatRows)
                if let peak = store.dailyPeak {
                    Text(peak.sentence)
                        .font(.caption)
                        .foregroundStyle(kind.palette.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .memory:
                chartCard(MemoryChart(history: store.memHistory,
                                      totalBytes: store.system.memoryTotalBytes,
                                      tint: kind.palette.dash, ink: kind.palette.ink).frame(height: 76))
                sectionCaption("构成")
                statRows([
                    ("联动", store.system.memoryWiredBytes.memoryText),
                    ("已压缩", store.system.memoryCompressedBytes.memoryText),
                    ("可清理", store.system.memoryCachedBytes.memoryText),
                    ("物理空闲", store.system.memoryFreeBytes.memoryText),
                    ("交换", "\(store.system.swapUsedBytes.memoryText) / \(store.system.swapTotalBytes.memoryText)"),
                ])
            case .network:
                chartCard(NetworkChart(down: store.netDownHistory, up: store.netUpHistory, tint: kind.palette.dash, upTint: kind.palette.ink.opacity(0.55), ink: kind.palette.ink).frame(height: 76))
                sectionCaption("速率与地址")
                statRows([("下载", "↓ " + store.net.inPerSec.speedText),
                          ("上传", "↑ " + store.net.outPerSec.speedText),
                          ("本机 IP", store.primaryLocalIP ?? "未连接")]
                         + store.localIPs.filter { $0.ip.contains(".") }.prefix(3)
                            .map { ($0.name, $0.ip) })
            case .disk:
                if let boot = store.volumes.first {
                    VolumeGauge(volume: boot, ink: kind.palette.ink)
                    let others = store.volumes.dropFirst()
                    if !others.isEmpty {
                        sectionCaption("其他卷")
                        statRows(others.map {
                            ($0.name, "剩 \($0.freeBytes.memoryText) / \($0.totalBytes.memoryText)")
                        })
                    }
                } else {
                    Text("未读取到卷信息")
                        .font(.callout)
                        .foregroundStyle(kind.palette.ink.opacity(0.6))
                }
            case .io:
                chartCard(NetworkChart(down: store.ioReadHistory,
                                       up: store.ioWriteHistory,
                                       tint: kind.palette.dash,
                                       upTint: kind.palette.ink.opacity(0.55),
                                       ink: kind.palette.ink).frame(height: 76))
                sectionCaption("速率与累计")
                statRows([
                    ("读取", "↓ " + store.diskIO.readBytesPerSec.speedText),
                    ("写入", "↑ " + store.diskIO.writeBytesPerSec.speedText),
                    ("IOPS(读 / 写)", "\(Int(store.diskIO.readOpsPerSec)) / \(Int(store.diskIO.writeOpsPerSec))"),
                    ("累计读取", store.diskIO.totalReadBytes.memoryText),
                    ("累计写入", store.diskIO.totalWrittenBytes.memoryText),
                ])
            case .battery:
                if let battery = store.battery {
                    BatteryGauge(battery: battery, ink: kind.palette.ink)
                } else {
                    Text("未检测到电池")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .glm:
                GLMPlanContent(status: store.glmPlan, ink: kind.palette.ink)
            case .java:
                JavaPanelContent(store: store)
            case .processes:
                ProcessPanelContent(store: store)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: DockGeom.panelWidth(kind),
               height: DockGeom.panelHeight(kind), alignment: .topLeading)
        .background(
            // 四角全圆的彩纸面板。
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(kind.palette.paper)
                .shadow(color: .black.opacity(0.30), radius: 16,
                        x: edge == .left ? 5 : -5, y: 4)
        )
        // 背向停靠边缘让出贴边卡片条的位置,不盖住展开的标签条。
        .padding(panelInset)
        .background(ProcessListHold(active: kind == .processes || kind == .java))
    }

    private var cpuStatRows: [(String, String)] {
        var rows = [
            ("用户", store.system.cpuUserPercent.percentText),
            ("系统", store.system.cpuSystemPercent.percentText),
            ("负载(1 分钟)", store.system.loadAverages.0.loadText),
            ("核心 / 已运行", "\(store.system.coreCount) · \(store.system.uptimeSeconds.uptimeText)"),
        ]
        if let name = store.digest.dominantName {
            rows.insert(("当前最忙", "\(name) \(store.digest.dominantCPU.percentText)"), at: 0)
        }
        return rows
    }

    private var panelInset: EdgeInsets {
        switch edge {
        case .right:  return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: DockGeom.tabWidth)
        case .left:   return EdgeInsets(top: 0, leading: DockGeom.tabWidth, bottom: 0, trailing: 0)
        case .bottomRight: return EdgeInsets(top: 0, leading: 0, bottom: DockGeom.tabWidth, trailing: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.35)))

            Text(kind.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.palette.ink.opacity(0.7))

            Spacer(minLength: 8)

            Text(headerValue)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.35), value: headerValue)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(kind.palette.ink.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    /// 图表放进浅底圆角卡,与数字行区分层次。
    private func chartCard<Content: View>(_ content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.30))
            )
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(kind.palette.ink.opacity(0.55))
            .padding(.leading, 2)
    }

    /// 面板主题色 = 对应卡片的色条色,整体配色与 deck 一致。
    private var accent: Color { kind.palette.dash }

    private var iconName: String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .io: return "arrow.up.arrow.down"
        case .battery: return "battery.100"
        case .glm: return "sparkles"
        case .java: return "cup.and.saucer"
        case .processes: return "list.bullet.rectangle"
        }
    }

    private var headerValue: String {
        switch kind {
        case .cpu: return store.system.cpuPercent.percentText
        case .memory:
            let ratio = store.system.memoryTotalBytes > 0
                ? Double(store.system.memoryUsedBytes) / Double(store.system.memoryTotalBytes) : 0
            return String(format: "%.0f%%", ratio * 100)
        case .network: return "↓ " + store.net.inPerSec.speedText
        case .disk:
            return store.volumes.first
                .map { "剩 \($0.freeBytes.memoryText)" } ?? "—"
        case .battery:
            return store.battery.map { "\(Int($0.percent.rounded()))%" } ?? "—"
        case .io: return store.diskIO.totalBytesPerSec.speedText
        case .glm:
            if let remaining = store.glmPlan?.fiveHour?.remainingPercent {
                return String(format: "%.0f%%", remaining)
            }
            return store.glmPlan?.error != nil ? "!" : "—"
        case .java:
            return store.digest.javaCount > 0 ? "\(store.digest.javaCount) 个" : "—"
        case .processes: return "\(store.digest.count)"
        }
    }

    private func statRows(_ rows: [(String, String)]) -> some View {
        StatRows(rows, ink: kind.palette.ink, valueInk: kind.palette.ink)
    }
}

/// 详情面板从边缘滑出:短滑动 + 锚定边缘的轻微缩放 + 淡入,由状态机里的弹簧驱动。
/// 滑程/缩放刻意收小:大面板(进程 440pt 宽)的比例下,长滑程会让面板
/// 先压在被点的卡片上"闪现"再挪到位,看起来是从点击位置冒出来抖了一下。
struct PanelPull: ViewModifier {
    let hidden: Bool
    var edge: DockEdge = .right

    func body(content: Content) -> some View {
        let anchor: UnitPoint
        let offset: CGSize
        switch edge {
        case .right:       anchor = .trailing; offset = CGSize(width: 24, height: 0)
        case .left:        anchor = .leading;  offset = CGSize(width: -24, height: 0)
        case .bottomRight:
                           anchor = .bottom;   offset = CGSize(width: 0, height: 24)
        }
        return content
            .offset(x: hidden ? offset.width : 0, y: hidden ? offset.height : 0)
            .scaleEffect(hidden ? 0.97 : 1, anchor: anchor)
            .opacity(hidden ? 0 : 1)
    }
}

/// Table(macOS 上是 NSScrollView + NSTableView 后端)挂载的头几拍会闪滚动条:
/// .scrollIndicators(.hidden) 对这套 AppKit 后端不总生效,而且滚动视图是本视图
/// 的兄弟子树(不是祖先),只能进窗口后在视图树里搜出来关掉。横竖两条都压:
/// 滚动本身靠滚轮/触控板,不需要看得见的滚动条。进窗口、每次 SwiftUI 更新都会
/// 尝试,直到关掉为止。同一时间面板窗口里只有一张表(进程/JVM),全局搜索是安全的。
private struct HideTableScrollers: NSViewRepresentable {
    typealias NSViewType = ScrollerKillView

    func makeNSView(context: Context) -> ScrollerKillView {
        let view = ScrollerKillView()
        view.tryDisable()
        return view
    }

    func updateNSView(_ view: ScrollerKillView, context: Context) {
        view.tryDisable()
    }
}

private final class ScrollerKillView: NSView {
    private weak var scrollView: NSScrollView?

    /// SwiftUI 每次 update 都会重新配置它背后的滚动视图,横向滚动条可能被
    /// 改回去,所以不设"完成"标记,每次更新都重新压一遍(幂等且廉价)。
    func tryDisable() {
        if let scrollView {
            apply(scrollView)
            return
        }
        disableInWindow()
        if scrollView == nil, window != nil {
            DispatchQueue.main.async { [weak self] in self?.tryDisable() }
        }
    }

    /// 首帧绘制前最后一次布局钩子——兄弟子树此时已装配完,在这里关掉
    /// 滚动条早于任何一帧上屏,闪烁没有露脸的机会。
    override func viewWillDraw() {
        super.viewWillDraw()
        tryDisable()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tryDisable()
    }

    private func apply(_ scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScroller?.removeFromSuperview()
        scrollView.horizontalScroller = nil
        scrollView.horizontalScrollElasticity = .none
        scrollView.hasVerticalScroller = false
        scrollView.verticalScroller?.removeFromSuperview()
        scrollView.verticalScroller = nil
    }

    private func disableInWindow() {
        guard let root = window?.contentView else { return }
        var stack: [NSView] = [root]
        while let node = stack.popLast() {
            if let scrollView = node as? NSScrollView {
                self.scrollView = scrollView
                apply(scrollView)
                return
            }
            stack.append(contentsOf: node.subviews)
        }
    }
}

// MARK: - Java 面板

/// JVM 进程列表:识别自可执行路径(/bin/java 结尾),业务标签取 -jar 包名
/// 或主类末段。汇总行 + 表格 + 强杀,交互与进程面板同款。
struct JavaPanelContent: View {
    @ObservedObject var store: MonitorStore
    @State private var selectedPID: Int32?
    @State private var killErrorText: String?
    @State private var sortOrder = [KeyPathComparator(\ProcInfo.cpuPercent, order: .reverse)]

    private var jvms: [ProcInfo] {
        store.processes.filter(\.isJava)
    }
    private var totalMemoryBytes: UInt64 { jvms.reduce(0) { $0 + $1.memoryBytes } }
    private var totalCPU: Double { jvms.reduce(0) { $0 + $1.cpuPercent } }

    var body: some View {
        VStack(spacing: 8) {
            if jvms.isEmpty {
                Text(store.digest.javaCount == 0 ? "没有正在运行的 Java 进程" : "正在读取…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 32)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 8) {
                    Text("\(jvms.count) 个 JVM · 合计内存 \(totalMemoryBytes.memoryText) · CPU \(totalCPU.percentText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        if let row = jvms.first(where: { $0.id == selectedPID }) { doKill(row) }
                    } label: {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.white, .red)
                    }
                    .disabled(selectedPID == nil)
                    .buttonStyle(.plain)
                    .help("强制退出选中进程")
                }
                Table(jvms, selection: $selectedPID, sortOrder: $sortOrder) {
                    TableColumn("进程", value: \.displayName) { row in
                        Text(row.javaLabel ?? row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contextMenu {
                                Button("强制退出 \(row.displayName)", role: .destructive) {
                                    doKill(row)
                                }
                            }
                    }
                    .width(min: 60, ideal: 270)
                    TableColumn("PID", value: \.pid) { row in
                        Text(String(row.pid))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 54, ideal: 64, max: 64)
                    TableColumn("CPU", value: \.cpuPercent) { row in
                        Text(row.cpuPercent.percentText)
                            .monospacedDigit()
                            .foregroundStyle(row.cpuPercent > 90 ? .red : (row.cpuPercent > 50 ? .orange : .primary))
                    }
                    .width(min: 54, ideal: 64, max: 64)
                    TableColumn("内存", value: \.memoryBytes) { row in
                        Text(row.memoryBytes.memoryText)
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 78, max: 78)
                    TableColumn("线程", value: \.threadCount) { row in
                        Text(String(row.threadCount))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 44, ideal: 50, max: 50)
                }
                .scrollIndicators(.hidden)
                .background(HideTableScrollers())
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .alert("无法退出进程", isPresented: Binding(
            get: { killErrorText != nil },
            set: { if !$0 { killErrorText = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(killErrorText ?? "")
        }
    }

    private func doKill(_ target: ProcInfo) {
        if store.forceQuit(pid: target.pid) { return }
        killErrorText = "无法结束 PID \(target.pid)(\(target.displayName))"
    }
}

// MARK: - 进程面板

/// 贴边只回答"这会儿是谁":CPU 和内存各前几名。搜索和全表在完整窗口。
struct ProcessPanelContent: View {
    @ObservedObject var store: MonitorStore

    @State private var confirmTarget: ProcInfo?
    @State private var killErrorText: String?

    private var ranked: [ProcInfo] {
        store.processes.filter { !ProcessDigest.noiseNames.contains($0.name) }
    }
    private var topCPU: [ProcInfo] {
        Array(ranked.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(6))
    }
    private var topMemory: [ProcInfo] {
        Array(ranked.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.processes.isEmpty {
                Text(store.digest.count == 0 ? "没有进程" : "正在读取…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
                Spacer(minLength: 0)
            } else {
                rankBlock("CPU", rows: topCPU) { $0.cpuPercent.percentText }
                rankBlock("内存", rows: topMemory) { $0.memoryBytes.memoryText }
                Spacer(minLength: 0)
                Button("打开完整窗口") {
                    (NSApp.delegate as? AppDelegate)?.openFullWindow()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .alert("强制退出进程", isPresented: Binding(
            get: { confirmTarget != nil },
            set: { if !$0 { confirmTarget = nil } }
        )) {
            Button("强制退出", role: .destructive) {
                if let target = confirmTarget { doKill(target) }
                confirmTarget = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要强制退出“\(confirmTarget?.displayName ?? "")”(PID \(confirmTarget?.pid ?? 0))吗?")
        }
        .alert("无法退出进程", isPresented: Binding(
            get: { killErrorText != nil },
            set: { if !$0 { killErrorText = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(killErrorText ?? "")
        }
    }

    private func rankBlock(_ title: String, rows: [ProcInfo],
                           metric: @escaping (ProcInfo) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.isJava ? "☕ \(row.displayName)" : row.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(metric(row))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(title == "CPU" && row.cpuPercent > 90 ? .red : .primary)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("强制退出 \(row.displayName)", role: .destructive) {
                        confirmTarget = row
                    }
                }
            }
        }
    }

    private func doKill(_ target: ProcInfo) {
        if store.forceQuit(pid: target.pid) { return }
        killErrorText = "无法结束 PID \(target.pid)(\(target.displayName))"
    }
}

/// 进程表 / Java 列表出现时才让采样把全表送到主线程。
struct ProcessListHold: View {
    let active: Bool
    @State private var held = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { sync(active) }
            .onDisappear {
                if held {
                    held = false
                    MonitorStore.shared.releaseProcessList()
                }
            }
            .onChange(of: active) { _, now in sync(now) }
    }

    private func sync(_ now: Bool) {
        if now && !held {
            held = true
            MonitorStore.shared.acquireProcessList()
        } else if !now && held {
            held = false
            MonitorStore.shared.releaseProcessList()
        }
    }
}

// MARK: - 磁盘面板

struct VolumeGauge: View {
    let volume: VolumeInfo
    var ink: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.14))
                    Capsule()
                        .fill(Color.loadTint(volume.usedFraction))
                        .frame(width: max(8, geo.size.width * volume.usedFraction))
                }
            }
            .frame(height: 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: volume.usedFraction)

            StatRows([
                ("总容量", volume.totalBytes.memoryText),
                ("已用", volume.usedBytes.memoryText),
                ("剩余", volume.freeBytes.memoryText),
            ], ink: ink, valueInk: ink)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 电池面板

struct BatteryGauge: View {
    let battery: BatteryInfo
    var ink: Color = .secondary

    private var color: Color { .batteryTint(battery) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.14))
                    Capsule()
                        .fill(color)
                        .frame(width: max(8, geo.size.width * battery.percent / 100))
                }
            }
            .frame(height: 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: battery.percent)

            StatRows([
                ("电量", "\(Int(battery.percent.rounded())) %"),
                ("状态", battery.isCharging ? "充电中" : (battery.onAC ? "已接电源" : "使用电池")),
                ("剩余", timeText),
            ], ink: ink, valueInk: ink)
            Spacer(minLength: 0)
        }
    }

    private var timeText: String {
        guard let minutes = battery.timeRemainingMinutes else {
            return battery.onAC && !battery.isCharging ? "—" : "正在计算"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return battery.isCharging ? "约 \(hours) 小时 \(mins) 分钟充满" : "约 \(hours) 小时 \(mins) 分钟"
    }
}

// MARK: - 智谱套餐面板

/// 智谱 GLM 编码套餐的余量:每个配额窗口一条"标签 + 余量 + 进度条",
/// 底部一行说明更新时间与错误。贴边详情面板与完整窗口共用。
struct GLMPlanContent: View {
    let status: GLMPlanStatus?
    var ink: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status {
                if status.windows.isEmpty, let error = status.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(ink.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(status.windows) { window in
                    windowRow(window)
                }
                Spacer(minLength: 0)
                Text(footerText(status))
                    .font(.caption2)
                    .foregroundStyle(ink.opacity(0.45))
            } else {
                Text("未设置 API Key。在「设置」里粘贴 bigmodel.cn 控制台的 API Key 后,这里会显示编码套餐余量。")
                    .font(.callout)
                    .foregroundStyle(ink.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func windowRow(_ window: GLMQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                Spacer()
                Text(window.remainingText.map { "剩 \($0)" }
                    ?? "剩 \(Int(window.remainingPercent.rounded()))%")
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            .font(.callout)
            .foregroundStyle(ink.opacity(0.85))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.14))
                    Capsule()
                        .fill(Color.loadTint(window.usedFraction))
                        .frame(width: max(8, geo.size.width * window.usedFraction))
                }
            }
            .frame(height: 9)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: window.usedFraction)

            Text(resetText(window.resetDate))
                .font(.caption)
                .foregroundStyle(ink.opacity(0.5))
        }
    }

    private func resetText(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "已到重置时间" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分后重置" }
        return "\(minutes) 分钟后重置"
    }

    private func footerText(_ status: GLMPlanStatus) -> String {
        let time = status.fetchedAt.formatted(date: .omitted, time: .shortened)
        let level = status.level.map { " · \($0.capitalized) 版" } ?? ""
        if let error = status.error {
            return "更新于 \(time) · \(error)"
        }
        return "更新于 \(time)\(level) · 数据来自 bigmodel.cn"
    }
}

// MARK: - 声音律动


/// 左下角的律动:没有外框,条从底边往上长。
struct PulseCornerView: View {
    var body: some View {
        PulseSpectrumCanvas()
            .padding(.horizontal, 2)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 细竖条站在底边上,只往上长。颜色跟设置走:自选一种,或每根条一个稳定的随机色。
struct PulseSpectrumCanvas: View {
    @ObservedObject private var model = PulseModel.shared
    @ObservedObject private var settings = CardSettings.shared

    var body: some View {
        let random = settings.pulseColorRandom
        let seed = settings.pulseColorSeed
        let fixed = settings.pulseColor
        Canvas { context, size in
            let bands = model.bands
            let count = bands.count
            let slot = size.width / CGFloat(count)
            let barWidth = max(2, slot * 0.35)
            for i in 0..<count {
                let value = bands[i]
                guard value > 0 else { continue }
                let h = size.height * CGFloat(value)
                guard h >= 1 else { continue }
                let rect = CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2,
                                  y: size.height - h,
                                  width: barWidth,
                                  height: h)
                let tint = random ? PulseBarColor.color(index: i, seed: seed) : fixed
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(tint.opacity(0.45 + 0.55 * value)))
            }
        }
    }
}

/// 由种子决定的每根条颜色。同一个种子每次算出来一样,不会跟着 30Hz 乱闪。
enum PulseBarColor {
    static func color(index: Int, seed: Int) -> Color {
        var state = UInt64(bitPattern: Int64(seed)) &+ UInt64(index) &* 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1
            return Double(state >> 33) / Double(1 << 31)
        }
        return Color(red: 0.28 + 0.72 * next(),
                     green: 0.28 + 0.72 * next(),
                     blue: 0.28 + 0.72 * next())
    }
}

/// 面板底部的"标签 — 数值"行列表,行间细分隔线,像一张小表。
struct StatRows: View {
    let rows: [(String, String)]
    var ink: Color = .secondary
    var valueInk: Color = .primary

    init(_ rows: [(String, String)], ink: Color = .secondary, valueInk: Color = .primary) {
        self.rows = rows
        self.ink = ink
        self.valueInk = valueInk
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.0).foregroundStyle(ink.opacity(0.72))
                    Spacer()
                    Text(row.1)
                        .foregroundStyle(valueInk)
                        .monospacedDigit()
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
                .padding(.vertical, 7)
                if index < rows.count - 1 {
                    Divider().opacity(0.45)
                }
            }
        }
    }
}

// MARK: - Shared bits

/// 只在外侧圆角,卡片读作"停靠在边缘上"(右缘圆左侧、左缘圆右侧、下缘圆顶部)。
func edgeTabShape(for edge: DockEdge, radius r: CGFloat = 11) -> UnevenRoundedRectangle {
    switch edge {
    case .right:
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                      bottomTrailingRadius: 0, topTrailingRadius: 0,
                                      style: .continuous)
    case .left:
        return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                      bottomTrailingRadius: r, topTrailingRadius: r,
                                      style: .continuous)
    case .bottomRight:
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0,
                                      bottomTrailingRadius: 0, topTrailingRadius: r,
                                      style: .continuous)
    }
}

struct EdgeLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

/// 右下角横排的出场序号。入场从右往左(靠右的是 0),退场从左往右。
/// 齿轮在最左,卡片 index 越大越靠右。
private func stageOrder(index: Int, totalCount: Int, revealed: Bool, edge: DockEdge) -> Int {
    guard edge == .bottomRight else {
        return revealed ? index : max(0, totalCount - 1 - index)
    }
    let gear = totalCount - 1
    let fromRight = index == gear ? gear : max(0, gear - 1 - index)
    return revealed ? fromRight : (gear - fromRight)
}

/// 依次弹入/弹出。延迟用定时器等,不用 Animation.delay:
/// delay 会先把卡片画到终点再弹回起点,看起来就是闪一下。
private struct Staged: ViewModifier {
    let index: Int
    let totalCount: Int
    let revealed: Bool
    let edge: DockEdge
    @State private var shown = false
    @State private var ticket = StageTicket()

    func body(content: Content) -> some View {
        let hiddenOffset = Self.hiddenOffset(for: edge)
        content
            .offset(x: shown ? 0 : hiddenOffset.width,
                    y: shown ? 0 : hiddenOffset.height)
            .compositingGroup()
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard revealed else { return }
                schedule(true)
            }
            .onChange(of: revealed) { _, newValue in
                schedule(newValue)
            }
    }

    private static func hiddenOffset(for edge: DockEdge) -> CGSize {
        switch edge {
        case .right: return CGSize(width: DockGeom.tabWidth + 24, height: 0)
        case .left: return CGSize(width: -(DockGeom.tabWidth + 24), height: 0)
        case .bottomRight: return CGSize(width: 0, height: DockGeom.tabWidth + 24)
        }
    }

    private func schedule(_ newValue: Bool) {
        ticket.value += 1
        let token = ticket.value
        let delay = Double(stageOrder(index: index, totalCount: totalCount,
                                       revealed: newValue, edge: edge))
            * DockGeom.stageInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard token == ticket.value, shown != newValue else { return }
            withAnimation(.spring(response: DockGeom.stageSpring, dampingFraction: 1)) {
                shown = newValue
            }
        }
    }
}

/// 退场改主意时作废还没开始的定时器。类是为了让延后的闭包读到最新序号。
private final class StageTicket {
    var value = 0
}

private extension View {
    func staged(index: Int, total: Int = 1, revealed: Bool, edge: DockEdge) -> some View {
        modifier(Staged(index: index, totalCount: total, revealed: revealed, edge: edge))
    }
}

struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 颜色

extension Color {
    /// 负载着色:<60% 绿,<85% 琥珀,其余红。
    static func loadTint(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }

    /// 电池着色:充电/电量充足绿,低电琥珀,危急红。
    static func batteryTint(_ battery: BatteryInfo) -> Color {
        if battery.isCharging || battery.percent >= 40 { return .green }
        if battery.percent >= 20 { return .orange }
        return .red
    }
}
