import AppKit

/// OCR 取字：框一块屏幕 → 里面的文字直接进剪贴板，一步完成。
///
/// 只在截图工具条上出现 —— 钉图窗口里同一张图早已入库，
/// 后台 OCR 的结果在图库详情栏里可以整段选中复制。
struct CopyTextAction: CaptureAction {
    let id = ActionID.copyText
    let title = "取字"
    let symbolName = "text.viewfinder"
    let scopes: Set<ActionScope> = [.capture]
    /// 用户要的是文字，别让全局自动复制用图片把它盖掉。
    let suppressesAutoCopy = true

    func perform(_ context: CaptureContext) async throws {
        // 对原图识别，不含标注 —— 画上去的箭头和高亮可能盖住文字。
        let text = await VisionOCR().recognizeText(in: context.base)
        guard !text.isEmpty else {
            NSLog("[MacShot] 取字：未识别到文字")
            return
        }
        Clipboard.copy(text: text)
    }
}
