import AppKit
import CoreGraphics

/// 显示器的静态描述。刻意不持有 NSScreen —— 选区状态机和渲染层不该依赖 AppKit 的可变对象。
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let name: String
    /// AppKit 全局坐标（左下原点）中的位置，单位是「点」。
    let frame: CGRect
    let scale: CGFloat

    init?(screen: NSScreen) {
        guard let id = Geometry.displayID(of: screen) else { return nil }
        self.id = id
        self.name = screen.localizedName
        self.frame = screen.frame
        self.scale = screen.backingScaleFactor
    }
}

/// 一块显示器在**某一瞬间**的冻结画面。
///
/// 这是整个截图流程的核心数据：快捷键按下的那一刻就把屏幕定格成位图，
/// 之后的选区、预览、裁剪全部对着它做。带来三件事：
///   1. 所见即所得 —— 选区期间画面不再变化，不会出现「框的是这一帧、存下来是那一帧」
///   2. 确认选区后无需再截屏，裁剪就是 `cropping(to:)`，零延迟
///   3. 放大镜 / 取色器可以直接采样像素，不用二次捕获
struct DisplaySnapshot {
    let display: DisplayInfo
    /// 物理像素位图（左上原点）。
    let image: CGImage

    var frame: CGRect { display.frame }
    var scale: CGFloat { display.scale }

    /// AppKit 全局矩形（点，左下原点）→ 位图局部像素矩形（左上原点）。
    func pixelRect(forGlobal rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - frame.minX) * scale,
            y: (frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    func crop(globalRect rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = pixelRect(forGlobal: rect).integral.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1,
              let sub = image.cropping(to: clipped) else { return nil }
        return Self.detached(sub)
    }

    /// `CGImage.cropping(to:)` 返回的是**引用原图后备存储**的视图，不是拷贝 ——
    /// 只要裁剪结果还活着，整张全屏位图（4K 屏约 33MB）就跟着活着。
    /// 钉图窗口和后台 OCR 都是长生命周期持有者，所以必须复制成独立位图。
    private static func detached(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
