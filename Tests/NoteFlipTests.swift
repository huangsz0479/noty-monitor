import AppKit
import Foundation
import QuartzCore

/// 翻书姿态与图层:同一位移不能抖,角度随手指单调变化,松手只提交一次。
@main
struct NoteFlipTests {
    static func main() {
        testPoseIsStable()
        testAngleFollowsFinger()
        testCommitDirection()
        testSecondEndIsIgnored()
        testResistedEdgeDoesNotCommit()
        testLayerDoesNotJitter()
        testBookTurnCommitsOnce()
        print("ok")
    }

    static func testPoseIsStable() {
        let first = NoteFlipMotion.pose(translation: -80, width: 300, allowsNext: true, allowsPrevious: true)
        for _ in 0..<40 {
            let again = NoteFlipMotion.pose(translation: -80, width: 300, allowsNext: true, allowsPrevious: true)
            expect(again == first, "同一位移的姿态必须相同")
        }
    }

    static func testAngleFollowsFinger() {
        var previous = CGFloat(0)
        for step in stride(from: CGFloat(0), through: -320, by: -5) {
            let pose = NoteFlipMotion.pose(translation: step, width: 320, allowsNext: true, allowsPrevious: true)
            expect(pose.curl + 0.00001 >= previous, "向左滑时掀页只能更开, step \(step)")
            previous = pose.curl
        }
        expect(abs(previous - 1) < 0.02, "滑满页宽时应完全掀开")

        previous = 0
        for step in stride(from: CGFloat(0), through: 320, by: 5) {
            let pose = NoteFlipMotion.pose(translation: step, width: 320, allowsNext: true, allowsPrevious: true)
            expect(pose.curl <= previous + 0.00001, "向右滑时进度只能更负")
            previous = pose.curl
        }
    }

    static func testCommitDirection() {
        var motion = NoteFlipMotion()
        motion.begin()
        motion.setTranslation(-90)
        let next = motion.end(cancelled: false, width: 300, allowsNext: true, allowsPrevious: true)
        expect(next == .commit(1), "向左滑过阈值去下一页")

        motion.begin()
        motion.setTranslation(90)
        let previous = motion.end(cancelled: false, width: 300, allowsNext: true, allowsPrevious: true)
        expect(previous == .commit(-1), "向右滑过阈值去上一页")

        motion.begin()
        motion.setTranslation(-20)
        let stay = motion.end(cancelled: false, width: 300, allowsNext: true, allowsPrevious: true)
        expect(stay == .cancel, "滑得不够应合上")
    }

    static func testSecondEndIsIgnored() {
        var motion = NoteFlipMotion()
        motion.begin()
        motion.setTranslation(-100)
        _ = motion.end(cancelled: false, width: 300, allowsNext: true, allowsPrevious: true)
        let again = motion.end(cancelled: false, width: 300, allowsNext: true, allowsPrevious: true)
        expect(again == .none, "松手之后不能再提交一次")
    }

    static func testResistedEdgeDoesNotCommit() {
        var motion = NoteFlipMotion()
        motion.begin()
        motion.setTranslation(120)
        let blocked = motion.end(cancelled: false, width: 300, allowsNext: true, allowsPrevious: false)
        expect(blocked == .cancel, "没有上一页时不能翻过去")
        let pose = NoteFlipMotion.pose(translation: 120, width: 300, allowsNext: true, allowsPrevious: false)
        expect(abs(pose.curl) < 0.08, "到头只轻轻掀起")
    }

    static func testLayerDoesNotJitter() {
        let view = NoteFlipView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        var motion = NoteFlipMotion()
        motion.begin()
        var previous = CGFloat(0)
        for step in stride(from: CGFloat(0), through: -160, by: -8) {
            motion.setTranslation(step)
            view.track(motion)
            expect(view.appliedCurl + 0.00001 >= previous, "掀页进度随手指向左单调")
            previous = view.appliedCurl
        }
        let held = view.appliedCurl
        for _ in 0..<30 {
            view.track(motion)
            view.layoutLeaf()
        }
        expect(abs(view.appliedCurl - held) < 0.00001, "停在中间反复布局,掀页不能抖")
    }

    static func testBookTurnCommitsOnce() {
        let view = NoteFlipView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        var commits: [Int] = []
        view.onCommit = { commits.append($0) }
        view.allowsNext = true
        view.allowsPrevious = true

        var motion = NoteFlipMotion()
        motion.begin()
        motion.setTranslation(-100)
        view.track(motion)
        view.turn(1)
        view.turn(1)
        spin(1.0)
        expect(commits == [1], "翻过去只换一次页,实际 \(commits)")
        expect(abs(view.appliedCurl) < 0.05, "翻完应合上,进度 \(view.appliedCurl)")
        testCurlLiftsBottomRight()
    }

    /// 右下角的红点会随着掀页离开原位,左上角在半程前仍是纸面。
    static func testCurlLiftsBottomRight() {
        let size = CGSize(width: 120, height: 160)
        let yellow = NotePageCurl.solid(NSColor(calibratedRed: 1, green: 0.91, blue: 0.55, alpha: 1), size: size)
        let red = NotePageCurl.solid(NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.1, alpha: 1), size: size)
            .cropped(to: CGRect(x: size.width - 24, y: 0, width: 24, height: 24))
        let front = red.composited(over: yellow)
        guard let early = NotePageCurl.render(front: front, time: 0.12, forward: true, size: size),
              let late = NotePageCurl.render(front: front, time: 0.82, forward: true, size: size) else {
            expect(false, "翻页滤镜没有出图")
            return
        }
        let earlyCorner = sample(early, x: Int(size.width) - 8, y: Int(size.height) - 8)
        let lateCorner = sample(late, x: Int(size.width) - 8, y: Int(size.height) - 8)
        let lateTop = sample(late, x: 16, y: 16)
        expect(earlyCorner.red - earlyCorner.blue > 0.4, "刚掀时右下角还是这一页的红点")
        expect(lateCorner.blue > earlyCorner.blue + 0.25, "掀开后右下角应露出下一页")
        expect(lateTop.red > 0.75 && lateTop.blue < 0.75, "左上角这时仍是这一页")
        testCurlLiftsTopLeft()
    }

    /// 回上一页时,左上角往右下掀。
    static func testCurlLiftsTopLeft() {
        let size = CGSize(width: 120, height: 160)
        let yellow = NotePageCurl.solid(NSColor(calibratedRed: 1, green: 0.91, blue: 0.55, alpha: 1), size: size)
        let blue = NotePageCurl.solid(NSColor(calibratedRed: 0.1, green: 0.25, blue: 0.85, alpha: 1), size: size)
            .cropped(to: CGRect(x: 0, y: size.height - 24, width: 24, height: 24))
        let front = blue.composited(over: yellow)
        guard let early = NotePageCurl.render(front: front, time: 0.12, forward: false, size: size),
              let late = NotePageCurl.render(front: front, time: 0.82, forward: false, size: size) else {
            expect(false, "回翻滤镜没有出图")
            return
        }
        let earlyCorner = sample(early, x: 8, y: 8)
        let lateCorner = sample(late, x: 8, y: 8)
        let lateBottom = sample(late, x: Int(size.width) - 16, y: Int(size.height) - 16)
        expect(earlyCorner.blue > 0.5 && earlyCorner.red < 0.35, "刚回翻时左上角还是这一页的蓝点")
        expect(lateCorner.red > 0.7, "掀开后左上角应离开,不再是蓝点")
        expect(lateBottom.red > 0.75 && lateBottom.blue < 0.75, "右下角这时仍是这一页")
    }

    static func sample(_ image: CGImage, x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        let color = rep.colorAt(x: x, y: y) ?? .black
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    static func spin(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: until)
        }
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("fail: \(message)\n", stderr)
            exit(1)
        }
    }
}
