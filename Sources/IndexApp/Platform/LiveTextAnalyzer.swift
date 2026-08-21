import CoreGraphics
import Foundation
import ImageIO
import VisionKit

/// 系统「实况文本」（Live Text）的封装：把一张位图交给 VisionKit 分析，
/// 产出可交互的 `ImageAnalysis`，塞进 `ImageAnalysisOverlayView` 就能在图上拖选文字。
///
/// 只负责「认出可选的字」—— 选择交互、词级命中、右键复制全部由系统 overlay 原生提供。
/// 和 `VisionOCR`（整段取字、落库）互补：这里的结果是临时交互，不落库。
@MainActor
enum LiveTextAnalyzer {

    /// Intel / 不支持的机型整个「选字」功能静默不出现，宿主据此决定要不要露出控件。
    static var isSupported: Bool { ImageAnalyzer.isSupported }

    /// 文档建议复用单个 analyzer 实例，避免每次分析都重新建模型。
    private static let analyzer = ImageAnalyzer()

    /// 失败（不支持、分析出错）一律返回 nil —— 上层拿不到结果就是没有可选的字。
    static func analyze(_ image: CGImage) async -> ImageAnalysis? {
        guard isSupported else { return nil }
        do {
            return try await analyzer.analyze(
                image,
                orientation: CGImagePropertyOrientation.up,
                configuration: ImageAnalyzer.Configuration([.text])
            )
        } catch {
            NSLog("[Index] Live Text 分析失败: \(error)")
            return nil
        }
    }
}
