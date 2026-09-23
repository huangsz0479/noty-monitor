import AppKit
import CoreImage
import Foundation

/// 翻书进度。正数是从右下角掀向左上角(下一页),负数是往回翻。0 是平放。
struct NoteFlipPose: Equatable {
    var curl: CGFloat

    static let flat = NoteFlipPose(curl: 0)

    var time: CGFloat { min(1, abs(curl)) }
}

enum NoteFlipEnd: Equatable {
    case none
    case cancel
    case commit(Int)
}

/// 翻页位移。负值是手指向左,去下一页,右下角往左上掀。
struct NoteFlipMotion {
    private(set) var translation: CGFloat = 0
    private var tracking = false

    static let commitFraction: CGFloat = 0.22
    static let commitMinimum: CGFloat = 72
    /// 下一页:右下角掀向左上角。上一页:左上角掀向右下角。角度用滤镜逐帧对过。
    static let forwardAngle: CGFloat = .pi * 0.75
    static let backAngle: CGFloat = -.pi / 4

    mutating func begin() {
        translation = 0
        tracking = true
    }

    func pose(width: CGFloat, allowsNext: Bool, allowsPrevious: Bool) -> NoteFlipPose {
        Self.pose(translation: translation, width: width,
                  allowsNext: allowsNext, allowsPrevious: allowsPrevious)
    }

    mutating func setTranslation(_ value: CGFloat) {
        guard tracking else { return }
        translation = value
    }

    mutating func end(cancelled: Bool, width: CGFloat, allowsNext: Bool, allowsPrevious: Bool) -> NoteFlipEnd {
        guard tracking else { return .none }
        tracking = false
        let value = translation
        translation = 0
        guard !cancelled else { return .cancel }
        let threshold = min(Self.commitMinimum, max(width, 1) * Self.commitFraction)
        if value <= -threshold, allowsNext { return .commit(1) }
        if value >= threshold, allowsPrevious { return .commit(-1) }
        return .cancel
    }

    static func pose(translation: CGFloat, width: CGFloat, allowsNext: Bool, allowsPrevious: Bool) -> NoteFlipPose {
        let span = max(width, 1)
        var travel = translation
        if travel < 0, !allowsNext { travel *= 0.12 }
        if travel > 0, !allowsPrevious { travel *= 0.12 }
        // 手指向左(负位移) → 正的掀页进度。
        let curl = max(-1, min(1, -travel / span))
        return NoteFlipPose(curl: curl)
    }
}

enum NotePageCurl {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(front: CIImage, time: CGFloat, forward: Bool, size: CGSize) -> CGImage? {
        let time = min(1, max(0, time))
        guard size.width > 1, size.height > 1 else { return nil }
        let extent = CGRect(origin: .zero, size: size)
        guard let filter = CIFilter(name: "CIPageCurlWithShadowTransition") else { return nil }
        filter.setValue(fit(front, to: size), forKey: kCIInputImageKey)
        filter.setValue(solid(paperTarget, size: size), forKey: kCIInputTargetImageKey)
        filter.setValue(solid(paperBack, size: size), forKey: "inputBacksideImage")
        filter.setValue(time, forKey: kCIInputTimeKey)
        filter.setValue(forward ? NoteFlipMotion.forwardAngle : NoteFlipMotion.backAngle, forKey: kCIInputAngleKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        filter.setValue(min(size.width, size.height) * 0.14, forKey: "inputRadius")
        filter.setValue(0.35, forKey: "inputShadowSize")
        filter.setValue(0.55, forKey: "inputShadowAmount")
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: extent)
    }

    static func solid(_ color: NSColor, size: CGSize) -> CIImage {
        CIImage(color: CIColor(color: color)!).cropped(to: CGRect(origin: .zero, size: size))
    }

    private static let paperTarget = NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.86, alpha: 1)
    private static let paperBack = NSColor(calibratedRed: 0.93, green: 0.78, blue: 0.42, alpha: 1)

    private static func fit(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return solid(paperTarget, size: size) }
        let transform = CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height)
        return image.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size))
    }
}
