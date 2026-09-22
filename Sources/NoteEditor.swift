import AppKit
import SwiftUI

/// 便签正文。源文仍是 Markdown,光标所在行露出标记,其余行按语法排版。没有单独的预览。
struct NoteMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var ink: Color
    var allowsNext: Bool
    var allowsPrevious: Bool
    var onCommit: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NoteFlipView {
        let flip = NoteFlipView()
        let textView = flip.textView
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.textContainer?.lineFragmentPadding = 4
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.onChange = { context.coordinator.commit($0) }

        context.coordinator.textView = textView
        return flip
    }

    func updateNSView(_ flip: NoteFlipView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        flip.onCommit = onCommit
        flip.allowsNext = allowsNext
        flip.allowsPrevious = allowsPrevious
        textView.ink = NSColor(ink).usingColorSpace(.sRGB) ?? .textColor
        flip.layoutLeaf()
        guard textView.string != text else { return }
        context.coordinator.styling = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        context.coordinator.styling = false
        textView.restyle()
        if !context.coordinator.didFocus, flip.window != nil {
            context.coordinator.didFocus = true
            flip.window?.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var textView: NoteTextView?
        var styling = false
        var didFocus = false

        init(text: Binding<String>) {
            _text = text
        }

        func commit(_ value: String) {
            guard text != value else { return }
            text = value
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !styling, let textView = notification.object as? NoteTextView else { return }
            textView.restyle()
        }
    }
}

final class NoteScrollView: NSScrollView {
    let tracker = NoteSwipeTracker()

    override func scrollWheel(with event: NSEvent) {
        if tracker.consume(event) { return }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let width = contentView.bounds.width
        guard width > 1 else { return }
        if abs(textView.frame.width - width) > 0.5 {
            textView.frame.size.width = width
        }
        textView.textContainer?.containerSize = NSSize(width: width,
                                                       height: CGFloat.greatestFiniteMagnitude)
    }
}

/// 左右滑驱动翻书。过程中只把位移交给书页图层,不碰 SwiftUI。
final class NoteSwipeTracker {
    weak var flip: NoteFlipView?
    /// 没有书页可转时(工具栏上的滑动)松手直接翻页。
    var onCommit: ((Int) -> Void)?
    var allowsNext = true
    var allowsPrevious = true
    private var accumX: CGFloat = 0
    private var accumY: CGFloat = 0
    private var axis = Axis.undecided
    private var settled = false
    private var motion = NoteFlipMotion()

    private enum Axis { case undecided, horizontal, vertical }

    func consume(_ event: NSEvent) -> Bool {
        if event.type == .swipe {
            let dx = event.deltaX
            guard abs(dx) >= abs(event.deltaY), abs(dx) > 0 else { return false }
            commit(dx > 0 ? -1 : 1)
            return true
        }
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? event.scrollingDeltaX : event.deltaX * 20
        let dy = precise ? event.scrollingDeltaY : event.deltaY * 20
        let phase = event.phase
        let momentum = event.momentumPhase
        let phased = !phase.isEmpty || !momentum.isEmpty

        if !phased {
            guard abs(dx) > abs(dy), abs(dx) > 0.5 else { return false }
            commit(dx < 0 ? 1 : -1)
            return true
        }
        if phase.contains(.began) {
            accumX = 0
            accumY = 0
            axis = .undecided
            settled = false
            motion.begin()
        }
        accumX += dx
        accumY += dy
        if phase.contains(.ended) || phase.contains(.cancelled) {
            return finish(cancelled: phase.contains(.cancelled))
        }
        if !momentum.isEmpty {
            if !settled { return finish(cancelled: false) }
            return true
        }
        if axis == .undecided {
            if abs(accumX) < 6, abs(accumY) < 6 { return false }
            axis = abs(accumX) > abs(accumY) ? .horizontal : .vertical
        }
        guard axis == .horizontal else { return false }
        motion.setTranslation(accumX)
        flip?.track(motion)
        return true
    }

    private func finish(cancelled: Bool) -> Bool {
        let horizontal = axis == .horizontal || (abs(accumX) > abs(accumY) && abs(accumX) > 8)
        accumX = 0
        accumY = 0
        axis = .undecided
        guard horizontal else {
            motion = NoteFlipMotion()
            return false
        }
        guard !settled else { return true }
        settled = true
        if cancelled {
            motion = NoteFlipMotion()
            flip?.restoreFlat()
            return true
        }
        let decision = motion.end(cancelled: false, width: flip?.bounds.width ?? 280,
                                  allowsNext: flip?.allowsNext ?? allowsNext,
                                  allowsPrevious: flip?.allowsPrevious ?? allowsPrevious)
        motion = NoteFlipMotion()
        switch decision {
        case .commit(let direction):
            if let flip {
                flip.turn(direction)
            } else {
                onCommit?(direction)
            }
        case .cancel:
            flip?.restoreFlat()
        case .none:
            break
        }
        return true
    }

    private func commit(_ direction: Int) {
        let allowed = direction > 0 ? (flip?.allowsNext ?? allowsNext) : (flip?.allowsPrevious ?? allowsPrevious)
        guard allowed else { return }
        if let flip {
            flip.turn(direction)
        } else {
            onCommit?(direction)
        }
    }
}

/// 书页。绕书脊做透视旋转,滑动时直接改图层,避免界面每帧重排。
final class NoteFlipView: NSView {
    let scroll = NoteScrollView()
    var textView: NoteTextView { scroll.documentView as! NoteTextView }
    var onCommit: ((Int) -> Void)?
    var allowsNext = true
    var allowsPrevious = true
    private(set) var appliedCurl: CGFloat = 0
    private var pose = NoteFlipPose.flat
    private var animating = false
    private var turning = false
    private let curlLayer = CALayer()
    private var frontImage: CIImage?
    private var animator: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.tracker.flip = self
        let text = NoteTextView()
        scroll.documentView = text
        addSubview(scroll)
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        wantsLayer = true
        curlLayer.contentsGravity = .resize
        curlLayer.isHidden = true
        layer?.addSublayer(curlLayer)
    }

    required init?(coder: NSCoder) { return nil }

    func layoutLeaf() {
        scroll.frame = bounds
        guard let textView = scroll.documentView as? NSTextView else { return }
        let width = scroll.contentView.bounds.width
        guard width > 1 else { return }
        if abs(textView.frame.width - width) > 0.5 {
            textView.frame.size.width = width
        }
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        curlLayer.frame = bounds
        if !animating { show(curl: pose.curl) }
    }

    override func layout() {
        super.layout()
        layoutLeaf()
    }

    /// 跟手掀页。同一进度重复设置不会改画面。
    func track(_ motion: NoteFlipMotion) {
        guard !animating, !turning else { return }
        let next = motion.pose(width: bounds.width, allowsNext: allowsNext, allowsPrevious: allowsPrevious)
        show(curl: next.curl)
    }

    func restoreFlat() {
        guard !turning else { return }
        animate(to: 0, completion: nil)
    }

    /// 右下角继续掀到左上角,掀过去再换成新的一页。
    func turn(_ direction: Int) {
        guard !turning else { return }
        turning = true
        let target: CGFloat = direction > 0 ? 1 : -1
        var delivered = false
        animate(to: target) {
            guard !delivered else { return }
            delivered = true
            self.onCommit?(direction)
            DispatchQueue.main.async {
                self.show(curl: 0)
                self.turning = false
            }
        }
    }

    private func show(curl: CGFloat) {
        pose = NoteFlipPose(curl: curl)
        appliedCurl = curl
        guard abs(curl) >= 0.012 else {
            curlLayer.isHidden = true
            curlLayer.contents = nil
            scroll.alphaValue = 1
            frontImage = nil
            return
        }
        if frontImage == nil { captureFront() }
        let size = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        guard let front = frontImage,
              let image = NotePageCurl.render(front: front, time: min(1, abs(curl)),
                                              forward: curl >= 0, size: size) else { return }
        scroll.alphaValue = 0
        curlLayer.frame = bounds
        curlLayer.isHidden = false
        curlLayer.contents = image
    }

    private func captureFront() {
        let rect = scroll.bounds
        guard rect.width > 1, rect.height > 1,
              let rep = scroll.bitmapImageRepForCachingDisplay(in: rect) else { return }
        scroll.cacheDisplay(in: rect, to: rep)
        guard let cg = rep.cgImage else { return }
        frontImage = CIImage(cgImage: cg)
    }

    private func animate(to target: CGFloat, completion: (() -> Void)?) {
        animator?.invalidate()
        animating = true
        let start = pose.curl
        let began = Date()
        let duration = 0.36
        animator = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let raw = min(1, Date().timeIntervalSince(began) / duration)
            let eased = raw * raw * (3 - 2 * raw)
            self.show(curl: start + (target - start) * eased)
            guard raw >= 1 else { return }
            timer.invalidate()
            self.animating = false
            completion?()
        }
    }
}

final class NoteTextView: NSTextView {
    var onChange: ((String) -> Void)?
    var ink: NSColor = .textColor
    private var styling = false

    override func swipe(with event: NSEvent) {
        guard let scroll = enclosingScrollView as? NoteScrollView, scroll.tracker.consume(event) else {
            super.swipe(with: event)
            return
        }
    }

    override func didChangeText() {
        super.didChangeText()
        guard !styling else { return }
        restyle()
        onChange?(string)
    }

    func restyle() {
        guard let storage = textStorage, !styling else { return }
        styling = true
        let selection = selectedRange()
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        MarkdownStyles.apply(to: storage, ink: ink, activeLine: activeLine(in: storage.string))
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        let length = (storage.string as NSString).length
        let clamped = NSRange(location: min(selection.location, length),
                              length: min(selection.length, max(0, length - min(selection.location, length))))
        setSelectedRange(clamped)
        styling = false
    }

    private func activeLine(in source: String) -> NSRange? {
        guard window?.firstResponder === self else { return nil }
        let ns = source as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let caret = min(selectedRange().location, ns.length)
        return ns.lineRange(for: NSRange(location: caret, length: 0))
    }
}

/// 按 Markdown 给正文上样式。标记字符留在源文里,非编辑行把它们收成几乎看不见。
enum MarkdownStyles {
    private static let bodySize: CGFloat = 13
    private static let headingSizes: [CGFloat] = [22, 18, 16, 15, 14, 13]

    static func apply(to storage: NSTextStorage, ink: NSColor, activeLine: NSRange?) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return }
        let body = NSFont.systemFont(ofSize: bodySize)
        storage.setAttributes([
            .font: body,
            .foregroundColor: ink,
            .paragraphStyle: paragraph(before: 1, after: 1),
        ], range: full)

        var index = 0
        var inCode = false
        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let content = withoutBreak(lineRange, in: ns)
            let active = activeLine.map { NSIntersectionRange($0, lineRange).length > 0 } ?? false
            let trimmed = ns.substring(with: content).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                styleFence(storage, range: content, ink: ink, active: active)
                inCode.toggle()
            } else if inCode {
                styleCode(storage, range: content, size: 12)
            } else {
                styleLine(storage, ns: ns, content: content, ink: ink, active: active, body: body)
            }
            index = lineRange.upperBound
        }
    }

    private static func styleLine(_ storage: NSTextStorage, ns: NSString, content: NSRange,
                                  ink: NSColor, active: Bool, body: NSFont) {
        guard content.length > 0 else { return }
        let line = ns.substring(with: content)
        if line.trimmingCharacters(in: .whitespaces) == "---"
            || line.trimmingCharacters(in: .whitespaces) == "***" {
            storage.addAttributes([
                .foregroundColor: ink.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 11),
            ], range: content)
            return
        }
        if let heading = headingPrefix(line) {
            let marker = NSRange(location: content.location, length: heading.marker)
            let rest = NSRange(location: content.location + heading.marker,
                               length: content.length - heading.marker)
            let size = headingSizes[min(heading.level - 1, headingSizes.count - 1)]
            let font = NSFont.systemFont(ofSize: size, weight: .bold)
            storage.addAttributes([
                .font: font,
                .paragraphStyle: paragraph(before: 8, after: 3),
            ], range: content)
            mark(storage, range: marker, ink: ink, active: active)
            styleInline(storage, ns: ns, range: rest, ink: ink, active: active, base: font)
            return
        }
        if let quote = prefixLength(line, pattern: "^[ \\t]*>[ \\t]?") {
            let marker = NSRange(location: content.location, length: quote)
            let rest = NSRange(location: content.location + quote, length: content.length - quote)
            let font = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
            storage.addAttributes([
                .font: font,
                .foregroundColor: ink.withAlphaComponent(0.78),
                .paragraphStyle: indented(14),
            ], range: content)
            mark(storage, range: marker, ink: ink, active: active)
            styleInline(storage, ns: ns, range: rest, ink: ink, active: active, base: font)
            return
        }
        if let list = prefixLength(line, pattern: "^[ \\t]*(?:[-*+]|\\d+\\.)[ \\t]+") {
            let marker = NSRange(location: content.location, length: list)
            let rest = NSRange(location: content.location + list, length: content.length - list)
            storage.addAttributes([
                .paragraphStyle: indented(18),
            ], range: content)
            storage.addAttributes([
                .foregroundColor: ink.withAlphaComponent(0.7),
                .font: NSFont.monospacedSystemFont(ofSize: bodySize, weight: .semibold),
            ], range: marker)
            styleInline(storage, ns: ns, range: rest, ink: ink, active: active, base: body)
            return
        }
        styleInline(storage, ns: ns, range: content, ink: ink, active: active, base: body)
    }

    private static func styleInline(_ storage: NSTextStorage, ns: NSString, range: NSRange,
                                    ink: NSColor, active: Bool, base: NSFont) {
        guard range.length > 0 else { return }
        var occupied: [NSRange] = []
        func claim(_ found: NSRange) -> Bool {
            guard found.length > 0, !occupied.contains(where: { NSIntersectionRange($0, found).length > 0 }) else {
                return false
            }
            occupied.append(found)
            return true
        }
        for match in matches("`[^`\\n]+`", in: ns, range: range) where claim(match) {
            styleCode(storage, range: match, size: bodySize - 1)
            concealEdges(storage, range: match, ink: ink, active: active, width: 1)
        }
        for match in matches("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", in: ns, range: range) where claim(match) {
            guard let re = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)"),
                  let found = re.firstMatch(in: ns as String, range: match),
                  found.numberOfRanges == 3 else { continue }
            let label = found.range(at: 1)
            if let url = URL(string: ns.substring(with: found.range(at: 2))) {
                storage.addAttributes([
                    .link: url,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: ink,
                ], range: label)
            }
            conceal(storage, range: NSRange(location: match.location, length: 1), ink: ink, active: active)
            let between = NSRange(location: label.location + label.length,
                                  length: match.location + match.length - (label.location + label.length))
            conceal(storage, range: between, ink: ink, active: active)
        }
        for match in matches("~~[^~\\n]+~~", in: ns, range: range) where claim(match) {
            let inner = innerRange(match, margin: 2)
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .font: base,
            ], range: inner)
            concealEdges(storage, range: match, ink: ink, active: active, width: 2)
        }
        for match in matches("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__", in: ns, range: range) where claim(match) {
            let inner = innerRange(match, margin: 2)
            let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            storage.addAttributes([.font: bold], range: inner)
            concealEdges(storage, range: match, ink: ink, active: active, width: 2)
        }
        for match in matches("\\*[^*\\n]+\\*|_[^_\\n]+_", in: ns, range: range) where claim(match) {
            let inner = innerRange(match, margin: 1)
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            storage.addAttributes([.font: italic], range: inner)
            concealEdges(storage, range: match, ink: ink, active: active, width: 1)
        }
    }

    private static func styleFence(_ storage: NSTextStorage, range: NSRange, ink: NSColor, active: Bool) {
        storage.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: ink.withAlphaComponent(active ? 0.45 : 0.01),
        ], range: range)
    }

    private static func styleCode(_ storage: NSTextStorage, range: NSRange, size: CGFloat) {
        storage.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .backgroundColor: NSColor.black.withAlphaComponent(0.08),
        ], range: range)
    }

    private static func mark(_ storage: NSTextStorage, range: NSRange, ink: NSColor, active: Bool) {
        conceal(storage, range: range, ink: ink, active: active)
    }

    private static func concealEdges(_ storage: NSTextStorage, range: NSRange, ink: NSColor,
                                     active: Bool, width: Int) {
        guard range.length > width * 2 else { return }
        conceal(storage, range: NSRange(location: range.location, length: width), ink: ink, active: active)
        conceal(storage, range: NSRange(location: range.location + range.length - width, length: width),
                ink: ink, active: active)
    }

    /// 正在编辑的那一行留下淡标记,其它行把标记收起来,只留排版结果。
    private static func conceal(_ storage: NSTextStorage, range: NSRange, ink: NSColor, active: Bool) {
        guard range.length > 0 else { return }
        if active {
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: ink.withAlphaComponent(0.35),
                .backgroundColor: NSColor.clear,
            ], range: range)
        } else {
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.01),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
            ], range: range)
        }
    }

    private static func headingPrefix(_ line: String) -> (level: Int, marker: Int)? {
        guard let match = prefixLength(line, pattern: "^#{1,6}[ \\t]+") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        return (hashes, match)
    }

    private static func prefixLength(_ line: String, pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.range.location == 0 else { return nil }
        return match.range.length
    }

    private static func matches(_ pattern: String, in ns: NSString, range: NSRange) -> [NSRange] {
        guard range.length > 0, let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: ns as String, options: [], range: range).map(\.range)
    }

    private static func innerRange(_ range: NSRange, margin: Int) -> NSRange {
        NSRange(location: range.location + margin, length: max(0, range.length - margin * 2))
    }

    private static func withoutBreak(_ lineRange: NSRange, in ns: NSString) -> NSRange {
        var range = lineRange
        while range.length > 0 {
            let ch = ns.character(at: range.location + range.length - 1)
            if ch == 0x0A || ch == 0x0D { range.length -= 1 } else { break }
        }
        return range
    }

    private static func paragraph(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = 2
        return style
    }

    private static func indented(_ points: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 2
        style.headIndent = points
        style.paragraphSpacing = 2
        style.lineSpacing = 2
        return style
    }
}
