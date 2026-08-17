import CoreGraphics

/// 一次截图后处理会话中的昂贵分析缓存。
///
/// 处理器仍彼此独立、并发执行；同一会话第一次请求文字结果时才启动 Vision，后续请求
/// 等待同一个 Task。缓存随 `PostProcessInput` 生命周期释放，不跨截图积累模型输入。
actor PostProcessAnalysis {
    typealias TextAnalyzer = @Sendable () async -> [VisionTextLine]

    private let textAnalyzer: TextAnalyzer
    private var textTask: Task<[VisionTextLine], Never>?

    init(image: CGImage) {
        textAnalyzer = { await VisionTextRecognition().recognize(in: image) }
    }

    init(textAnalyzer: @escaping TextAnalyzer) {
        self.textAnalyzer = textAnalyzer
    }

    func recognizedText() async -> [VisionTextLine] {
        if let textTask { return await textTask.value }
        let analyzer = textAnalyzer
        let task = Task { await analyzer() }
        textTask = task
        return await task.value
    }
}
