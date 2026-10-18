import AppKit
import CoreGraphics

/// 显示器的静态描述。刻意不持有 NSScreen —— 选区状态机和渲染层不该依赖 AppKit 的可变对象。
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let name: String
    /// AppKit 全局坐标（左下原点）中的位置，单位是「点」。
    let frame: CGRect
    let scale: CGFloat

    init(id: CGDirectDisplayID, name: String, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.name = name
        self.frame = frame
        self.scale = scale
    }

    init?(screen: NSScreen) {
        guard let id = Geometry.displayID(of: screen) else { return nil }
        self.init(
            id: id,
            name: screen.localizedName,
            frame: screen.frame,
            scale: screen.backingScaleFactor
        )
    }
}

/// 判断两次读取是否仍是同一份活动显示器拓扑。
/// 不只比较 displayID：旋转、缩放或排列变化也会让旧位图坐标失效。
enum DisplayTopology {
    static func matches(_ expected: [DisplayInfo], _ actual: [DisplayInfo]) -> Bool {
        guard expected.count == actual.count else { return false }
        return expected.allSatisfy { expectedDisplay in
            actual.contains { actualDisplay in
                actualDisplay == expectedDisplay
            }
        }
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
    /// 捕获位图（左上原点）。位图 scale 与显示器拓扑 scale 分开保存，
    /// 以兼容外部捕获源或将来可能采用的不同像素密度。
    let image: CGImage
    /// 位图像素 / 显示器点。与 `display.scale` 分开：后者只描述当前
    /// 显示器拓扑，用于判断 Sidecar/分辨率是否在捕获期间变化。
    let imageScale: CGFloat

    init(display: DisplayInfo, image: CGImage, imageScale: CGFloat? = nil) {
        self.display = display
        self.image = image
        self.imageScale = imageScale ?? display.scale
    }

    var frame: CGRect { display.frame }
    var scale: CGFloat { imageScale }

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

    /// 多边形裁剪：按顶点路径 clip，多边形外区域透明。
    /// 顶点为 AppKit 全局坐标（左下原点，点），≥ 3 个。
    /// 当前未调用（`makeCroppedImage` 走 bbox 矩形裁剪），保留供恢复多边形 alpha 裁剪用。
    func crop(polygon: [CGPoint]) -> CGImage? {
        guard polygon.count >= 3 else { return nil }
        let bbox = polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard bbox.width > 0, bbox.height > 0 else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelBBox = pixelRect(forGlobal: bbox).integral
        let clipped = pixelBBox.intersection(bounds)
        guard clipped.width >= 1, clipped.height >= 1,
              let base = image.cropping(to: clipped) else { return nil }

        let width = Int(clipped.width)
        let height = Int(clipped.height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 先清除整个 ctx（全透明），再裁剪到多边形内绘制。
        // ctx.makeImage() 可能返回 noneSkipLast（无 alpha），
        // 所以从 ctx.data 显式建图，指定 premultipliedLast。
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // 翻转 Y 轴：ctx.data 像素第一行是底部（左下原点），
        // 但 CGImage 约定第一行是顶部。翻转后两者一致。
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // 全局坐标（左下原点）→ 翻转后的 CGContext（左上原点）。
        let path = CGMutablePath()
        for (i, point) in polygon.enumerated() {
            let ctxPoint = CGPoint(
                x: (point.x - bbox.minX) * scale,
                y: CGFloat(height) - (point.y - bbox.minY) * scale
            )
            if i == 0 { path.move(to: ctxPoint) } else { path.addLine(to: ctxPoint) }
        }
        path.closeSubpath()

        ctx.addPath(path)
        ctx.clip()
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bytesPerRow = width * 4
        guard let pixelPtr = ctx.data else { return nil }
        let pixelData = Data(
            bytes: pixelPtr.assumingMemoryBound(to: UInt8.self),
            count: bytesPerRow * height
        )
        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
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
