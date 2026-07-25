import AppKit

/// 一次截图选区的最终产物。
///
/// 到这里像素已经裁好了 —— 冻结架构下确认选区之后不需要再截屏。
struct SelectionResult {
    /// AppKit 全局坐标。
    let region: CGRect
    let display: DisplayInfo
    /// 单击窗口选中时非空，用于元数据归因。
    let window: WindowInfo?
    let action: ToolbarAction
    /// 从冻结画面裁好的像素，**不含标注**。
    let image: CGImage
    /// 截图时画的标注，坐标已换算到裁剪图的像素空间。
    /// 原图保持干净，这些作为一条修订入库。
    let layers: [Layer]
}
