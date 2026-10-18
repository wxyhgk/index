import AppKit
import CoreGraphics

/// 把跨多块屏的选区拼成一张图。
///
/// 输出分辨率由活动屏（拖拽起点所在屏）的 scale 决定；其它屏按比例缩放绘制。
/// 屏幕之间的空档保持透明——它们本来就不在任何显示器上。
enum MultiDisplayComposer {

    static func stitch(
        region: CGRect,
        snapshots: [DisplaySnapshot],
        outputScale: CGFloat
    ) -> CGImage? {
        guard outputScale > 0, !snapshots.isEmpty else { return nil }
        let width = Int((region.width * outputScale).rounded())
        let height = Int((region.height * outputScale).rounded())
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        for snapshot in snapshots {
            let intersection = snapshot.display.frame.intersection(region)
            guard !intersection.isEmpty,
                  let crop = snapshot.crop(globalRect: intersection)
            else { continue }

            // CGContext 原点在左下；region.minY 对应输出底边。
            let dest = CGRect(
                x: (intersection.minX - region.minX) * outputScale,
                y: (intersection.minY - region.minY) * outputScale,
                width: intersection.width * outputScale,
                height: intersection.height * outputScale
            )
            ctx.draw(crop, in: dest)
        }
        return ctx.makeImage()
    }
}

extension Layer {
    /// 跨屏拼接后，把标注从「活动屏裁剪图坐标」平移到「拼接图坐标」。
    func offsetBy(dx: Double, dy: Double) -> Layer {
        var copy = self
        copy.rect.x += dx
        copy.rect.y += dy
        if let points = copy.strokePoints {
            copy.strokePoints = points.map {
                CGPoint(x: $0.x + dx, y: $0.y + dy)
            }
        }
        if let origin = copy.magnifierDisplayOrigin {
            copy.magnifierDisplayOrigin = CGPoint(x: origin.x + dx, y: origin.y + dy)
        }
        return copy
    }
}

extension Layers {
    func offsetBy(dx: Double, dy: Double) -> Layers {
        Layers(elements.map { $0.offsetBy(dx: dx, dy: dy) })
    }
}
