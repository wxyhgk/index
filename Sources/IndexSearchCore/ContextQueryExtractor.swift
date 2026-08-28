import Foundation

/// 从光标前的小段已提交文本中提取当前检索短语。
///
/// 辅助功能模式读取的是客户端最终文本，因此可以和苹果拼音、微信输入法等任意 IME 共存。
/// 这里只处理纯文本边界，不认识 AppKit 或 Accessibility。
public enum ContextQueryExtractor {
    public static func query(
        fromTextBeforeCaret text: String,
        maximumLength: Int = 64
    ) -> String? {
        guard maximumLength > 0 else { return nil }
        var buffer = InputQueryBuffer(maximumLength: maximumLength)
        return buffer.consume(.text(String(text.suffix(maximumLength))))
    }
}
