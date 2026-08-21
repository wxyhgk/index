import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// MobileCLIP-S0 编码器：图像 / 文本 → 512 维**已归一化**向量。
///
/// 图文向量在同一语义空间里，归一化后余弦相似度就是点积 ——
/// 「蓝色渐变的 dashboard」这句话的向量和一张蓝色渐变截图的向量会离得很近。
///
/// actor 串行化模型的懒加载与缓存；推理由 CoreML 自行调度到 ANE / GPU。
/// 模型未下载（`CLIPModelStore`）时所有方法安静地返回 nil。
actor CLIPEncoder {

    static let shared = CLIPEncoder()

    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?

    // MARK: - 编码

    /// 图像 → 归一化向量。预处理：拉伸缩放到模型输入尺寸（S0 为 256×256）的
    /// BGRA 像素缓冲；归一化在模型内部完成（Apple 官方转换时已内置）。
    /// 截图选择拉伸而非居中裁剪 —— 界面截图的语义常分布在边缘（工具条、侧栏），
    /// 裁掉比轻微变形损失更大。
    func embedImage(_ image: CGImage) async -> [Float]? {
        guard let model = loadedImageModel(),
              let input = Self.imageInputDescription(of: model),
              let buffer = Self.pixelBuffer(from: image, width: input.width, height: input.height),
              let provider = try? MLDictionaryFeatureProvider(
                dictionary: [input.name: MLFeatureValue(pixelBuffer: buffer)]
              ),
              let output = try? await model.prediction(from: provider, options: MLPredictionOptions()),
              let vector = Self.firstVector(in: output)
        else { return nil }
        return Self.normalized(vector)
    }

    /// 查询文本 → 归一化向量。BPE 分词（77 token 上限，含起止符）后推理。
    func embedText(_ query: String) async -> [Float]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let model = loadedTextModel(),
              let tokenizer = loadedTokenizer(),
              let inputName = Self.multiArrayInputName(of: model)
        else { return nil }

        let tokens = tokenizer.encode(trimmed)
        guard let array = try? MLMultiArray(
            shape: [1, NSNumber(value: tokens.count)],
            dataType: .int32
        ) else { return nil }
        for (index, token) in tokens.enumerated() {
            array[index] = NSNumber(value: token)
        }

        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: array)]
              ),
              let output = try? await model.prediction(from: provider, options: MLPredictionOptions()),
              let vector = Self.firstVector(in: output)
        else { return nil }
        return Self.normalized(vector)
    }

    /// 模型被删除（设置页）后丢掉缓存，下次调用重新走加载路径。
    func unload() {
        imageModel = nil
        textModel = nil
        tokenizer = nil
    }

    // MARK: - 相似度与序列化

    /// 归一化向量的余弦相似度就是点积。维度不一致返回 0（视为不相关）。
    static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return 0 }
        var sum: Float = 0
        for i in 0..<lhs.count { sum += lhs[i] * rhs[i] }
        return sum
    }

    /// [Float] → 落库的原始字节（小端 Float32 连续排列）。
    static func data(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 落库字节 → [Float]。长度不是 4 的倍数视为损坏，返回 nil。
    static func vector(from data: Data) -> [Float]? {
        let stride = MemoryLayout<Float>.stride
        guard !data.isEmpty, data.count % stride == 0 else { return nil }
        let count = data.count / stride
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            _ = data.copyBytes(to: buffer)
            initialized = count
        }
    }

    // MARK: - 模型加载

    private func loadedImageModel() -> MLModel? {
        if let imageModel { return imageModel }
        imageModel = Self.load(CLIPModelLocation.compiledImageModel)
        return imageModel
    }

    private func loadedTextModel() -> MLModel? {
        if let textModel { return textModel }
        textModel = Self.load(CLIPModelLocation.compiledTextModel)
        return textModel
    }

    private func loadedTokenizer() -> CLIPTokenizer? {
        if let tokenizer { return tokenizer }
        tokenizer = try? CLIPTokenizer(vocabURL: CLIPModelLocation.vocab)
        return tokenizer
    }

    private static func load(_ url: URL) -> MLModel? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            NSLog("[Index] CLIP 模型加载失败: \(error)")
            return nil
        }
    }

    // MARK: - CoreML 桥接

    /// 图像输入的名字和尺寸从模型描述里读，不硬编码 —— 换模型不用改代码。
    private static func imageInputDescription(
        of model: MLModel
    ) -> (name: String, width: Int, height: Int)? {
        for (name, description) in model.modelDescription.inputDescriptionsByName {
            guard let constraint = description.imageConstraint else { continue }
            return (name, constraint.pixelsWide, constraint.pixelsHigh)
        }
        return nil
    }

    private static func multiArrayInputName(of model: MLModel) -> String? {
        model.modelDescription.inputDescriptionsByName
            .first { $0.value.multiArrayConstraint != nil }?
            .key
    }

    /// 输出特征名因转换版本而异（如 var_1259），取第一个 multiArray 输出即可。
    private static func firstVector(in output: MLFeatureProvider) -> [Float]? {
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue else { continue }
            var vector = [Float](repeating: 0, count: array.count)
            for i in 0..<array.count { vector[i] = array[i].floatValue }
            return vector
        }
        return nil
    }

    private static func normalized(_ vector: [Float]) -> [Float]? {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return nil }
        let inverse = 1 / sum.squareRoot()
        return vector.map { $0 * inverse }
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue as Any
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
