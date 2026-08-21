import CoreGraphics
import Foundation

/// 发送给智能能力的最小像素材料。
///
/// 这里刻意没有 shotID、整张截图或数据库对象：调用方必须先裁出用户明确框选的区域，
/// Provider 只能看到这块局部像素。`recognizedText` 可复用 Index 已有 OCR，避免云端
/// Provider 为纯文字任务再次上传/识别整块图片。
struct SelectionAIInput: @unchecked Sendable {
    let image: CGImage
    let recognizedText: String?

    init(image: CGImage, recognizedText: String? = nil) {
        self.image = image
        self.recognizedText = recognizedText
    }

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

struct SelectionAIRequest: @unchecked Sendable {
    let id: UUID
    let task: SelectionAITask
    let input: SelectionAIInput
    /// 用户对本次任务追加的上下文；nil 表示使用任务默认指令。
    let instruction: String?

    init(
        id: UUID = UUID(),
        task: SelectionAITask,
        input: SelectionAIInput,
        instruction: String? = nil
    ) {
        self.id = id
        self.task = task
        self.input = input
        self.instruction = instruction
    }
}
