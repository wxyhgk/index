import CoreGraphics
import Foundation
import VisionKit

/// Live Text 分析结果的进程级缓存。
///
/// 命中判定用**自己的 OCR 文字框**（`ocrRects`，图像像素坐标、左上原点），
/// 不依赖 VisionKit 的 `hasInteractiveItem`（它绑定 analysis 后还要数秒到
/// 十余秒才建好词级空间索引，期间恒为 false —— 表现为「时灵时不灵」）。
/// `ImageAnalysis` 只用于实际拖选高亮与 ⌘C 复制。
///
/// 同一张截图再次打开编辑器时直接复用上一份结果，跳过重新推理。
///
/// 键 =（截图 ID、底图像素尺寸、马赛克图层）：原图字节不可变，尺寸用来
/// 区分占位图与真图，马赛克是唯一会改变分析输入的因素（打了码的字不该
/// 还能选出来，所以它必须参与判等）。
///
/// 只在主线程访问（CanvasView 的回调与落地闭包都在主线程执行）。
enum LiveTextAnalysisCache {

    private struct Entry {
        let shotID: Int64
        let size: CGSize
        let pixelates: Layers<ImageSpace>
        let analysis: ImageAnalysis
        /// OCR 文字框（图像像素坐标、左上原点）。命中判定用它，立即可用。
        let ocrRects: [CGRect]
    }

    /// 条目上限。每条持有一张图的词级识别数据，小上限即可控制内存；
    /// 超出按最近使用淘汰（写入即提到最前）。
    private static let limit = 8
    private static var entries: [Entry] = []

    static func lookup(shotID: Int64, size: CGSize, pixelates: Layers<ImageSpace>) -> (analysis: ImageAnalysis, ocrRects: [CGRect])? {
        guard let i = entries.firstIndex(where: {
            $0.shotID == shotID && $0.size == size && $0.pixelates == pixelates
        }) else { return nil }
        return (entries[i].analysis, entries[i].ocrRects)
    }

    /// 只缓存非 nil 结果：分析失败或无文字时不占坑，下次打开会重试一次。
    static func store(
        shotID: Int64,
        size: CGSize,
        pixelates: Layers<ImageSpace>,
        analysis: ImageAnalysis,
        ocrRects: [CGRect]
    ) {
        entries.removeAll {
            $0.shotID == shotID && $0.size == size && $0.pixelates == pixelates
        }
        entries.insert(
            Entry(shotID: shotID, size: size, pixelates: pixelates, analysis: analysis, ocrRects: ocrRects),
            at: 0
        )
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }
}
