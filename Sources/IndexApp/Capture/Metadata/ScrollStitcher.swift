import Foundation
import Accelerate
import CoreGraphics
import CoreVideo

/// 滚动拼接的一帧输入：紧凑 RGBA8 像素，行优先，行 0 在顶部。
/// 与 CGImage 解耦 —— 算法核心只看字节，纯函数、可脱离 AppKit 测试。
struct ScrollFrame {
    let width: Int          // 像素
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]     // RGBA8

    func rowStart(_ row: Int) -> Int { row * bytesPerRow }
}

/// 「用户手动滚动，我们自动拼接」的核心算法（Xnip 路线：重叠检测自动拼接，
/// 找不到重叠就暂停等待）。刻意不合成滚动事件 —— 那需要辅助功能权限且各 App 行为不一。
///
/// 工作方式：
///   1. 每帧降采样成「行签名」：每行按宽度分成 `hashWidth` 个桶，桶内采样取灰度均值，
///      一行变成一个长度 64 的向量。对齐只比签名，不比原始像素。
///   2. 拿拼接结果**尾部 `anchorRows` 行**的签名做锚，在新帧的中段自上而下滑动，
///      找平均绝对差最小且低于 `maxMeanDiff` 的对齐位置。
///   3. 找到对齐 → 追加帧上对齐点以下的新增行；
///      帧与上一帧签名全等 → 用户没滚，跳过；
///      找不到可靠对齐 → 用户滚太快（或向上滚 / 内容在动画），忽略该帧，
///      等用户滚回能接上的位置再继续 —— 宁可暂停也不错拼。
///
/// **固定页头/页尾策略**（滚动截图最经典的失败源）：
///   浏览器的固定导航栏、悬浮工具条通常贴在视口顶部或底部，不随内容滚动。
///   拿这些行参与对齐会把「没滚」误判成完美对齐；拿它们参与追加会让导航栏
///   在长图里反复出现。因此：
///   · 对齐与追加都**只用中段** —— 忽略帧顶部和底部各 `edgeIgnoreFraction`（15%）的行；
///   · 首帧例外：顶部 15% 照常收录 —— 滚动起点的页头是页面真实的开头，只该出现这一次；
///   · 底部 15% 每帧先扣下（`pendingBottom`），`finalize()` 时把**最后一帧**的底部补回，
///     页面真正的结尾不会被裁掉，固定页尾最多出现一次（在长图最底部）。
struct ScrollStitcher {

    struct Config {
        /// 行签名的桶数：一行降采样成 64 个灰度均值。
        var hashWidth = 64
        /// 忽略帧顶部和底部各占的比例（固定页头/页尾通常在这里）。
        var edgeIgnoreFraction: Double = 0.15
        /// 用拼接结果尾部多少行做对齐锚。
        var anchorRows = 32
        /// 对齐接受阈值：锚区行签名的平均绝对差（0–255 灰度刻度）。
        /// 内容按整数像素滚动时应接近 0；阈值放宽到 6 以容忍
        /// 亚像素滚动的重采样和右缘悬浮滚动条的干扰。
        var maxMeanDiff: Float = 6.0
        /// 并列容差：代价与最优相差不超过它的候选里取滚动量最小的那个 ——
        /// 纯色区域会出现大片近零代价的假对齐，保守选择保证接缝依然无缝。
        var tieEpsilon: Float = 0.75
        /// 拼接高度上限（像素）。到达后强制完成，防止内存失控。
        var maxHeight = 30000
    }

    enum AppendOutcome: Equatable {
        /// 第一帧，整体收录（不含底部 15%）。
        case seeded(rows: Int)
        /// 找到重叠，追加了这么多新行。
        case appended(rows: Int)
        /// 与上一帧相同（用户没滚），跳过。
        case unchanged
        /// 找不到可靠重叠（滚太快 / 向上滚 / 画面在动），该帧被忽略。
        case noOverlap
        /// 已达高度上限，调用方应立即完成。
        case limitReached
    }

    let config: Config

    /// 拼接结果的宽（像素），由首帧决定。
    private(set) var width = 0
    /// 拼接结果当前的高（像素行数）。
    private(set) var height = 0

    private var rowBytes = 0
    /// 拼接缓冲：紧凑 RGBA8，height * rowBytes 字节。
    private var stitched: [UInt8] = []
    /// 与 stitched 逐行对应的签名（finalize 补入的底部行除外，那之后不再匹配）。
    private var signatures: [[Float]] = []
    /// 上一帧的签名，用于「用户没滚」的快速判定。
    private var lastFrameSignatures: [[Float]]?
    /// 最后一个成功帧被扣下的底部 15% 行，finalize 时补回。
    private var pendingBottom: [UInt8] = []
    private var pendingBottomRows = 0
    private var finalized = false

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - 追加一帧

    mutating func append(_ frame: ScrollFrame) -> AppendOutcome {
        append(frame, signatures: Self.signatures(of: frame, config: config))
    }

    /// 同 `append(_:)`，但复用调用方已算好的行签名（必须出自同一 `config` 的
    /// `signatures(of:config:)`）。连续流采集在后台队列先算签名做去重节流，
    /// 通过后原样传回来 —— 一帧的签名只算一次。
    mutating func append(_ frame: ScrollFrame, signatures sigs: [[Float]]) -> AppendOutcome {
        guard !finalized, height < config.maxHeight else { return .limitReached }
        guard frame.width > 0, frame.height > 0 else { return .noOverlap }

        let edge = Int(Double(frame.height) * config.edgeIgnoreFraction)
        let bandEnd = frame.height - edge

        // 首帧：从页面顶部收录到带底。顶部 15% 不忽略 —— 见类型注释的页头策略。
        if signatures.isEmpty {
            width = frame.width
            rowBytes = frame.width * 4
            appendRows(from: frame, rows: 0..<bandEnd, signatures: sigs)
            storePendingBottom(frame, from: bandEnd)
            lastFrameSignatures = sigs
            return .seeded(rows: bandEnd)
        }

        guard frame.width == width else { return .noOverlap }

        // 与上一帧全等 → 用户没滚。
        if let last = lastFrameSignatures, last == sigs { return .unchanged }

        // 对齐锚必须整体落在中段带内：候选 p 是「拼接结果最后一行」在帧里的行号。
        let anchorLen = min(config.anchorRows, signatures.count)
        let minP = edge + anchorLen - 1
        let maxP = bandEnd - 1
        guard minP <= maxP else { return .noOverlap }

        guard let p = Self.findAlignment(
            anchor: Array(signatures.suffix(anchorLen)),
            frame: sigs,
            candidates: minP...maxP,
            maxMeanDiff: config.maxMeanDiff,
            tieEpsilon: config.tieEpsilon
        ) else { return .noOverlap }

        lastFrameSignatures = sigs

        var newRows = maxP - p
        if newRows == 0 {
            // 对齐点就在带底：内容没动（或动了不到一行）。底部可能有变化，刷新扣存。
            storePendingBottom(frame, from: bandEnd)
            return .unchanged
        }

        var limited = false
        if height + newRows > config.maxHeight {
            newRows = config.maxHeight - height
            limited = true
        }

        let range = (p + 1)..<(p + 1 + newRows)
        appendRows(from: frame, rows: range, signatures: sigs)

        if limited {
            // 截断追加后拼接尾与帧的带底不再连续，底部补回会产生错位接缝 —— 丢弃。
            pendingBottom.removeAll()
            pendingBottomRows = 0
            return .limitReached
        }

        storePendingBottom(frame, from: bandEnd)
        return .appended(rows: newRows)
    }

    /// 采集结束时调用：把最后一帧被扣下的底部 15% 补回（固定页尾最多出现这一次）。
    /// 返回补了多少行。
    @discardableResult
    mutating func finalize() -> Int {
        guard !finalized else { return 0 }
        finalized = true

        var rows = pendingBottomRows
        if height + rows > config.maxHeight { rows = max(0, config.maxHeight - height) }
        guard rows > 0 else { return 0 }

        stitched.append(contentsOf: pendingBottom[0..<(rows * rowBytes)])
        height += rows
        return rows
    }

    /// 拼接结果 → CGImage（sRGB，RGBA8）。
    func makeImage() -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(stitched) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - 私有

    private mutating func appendRows(from frame: ScrollFrame, rows: Range<Int>, signatures sigs: [[Float]]) {
        let copyBytes = width * 4
        for row in rows {
            let start = frame.rowStart(row)
            stitched.append(contentsOf: frame.pixels[start..<(start + copyBytes)])
        }
        signatures.append(contentsOf: sigs[rows])
        height += rows.count
    }

    private mutating func storePendingBottom(_ frame: ScrollFrame, from bandEnd: Int) {
        pendingBottom.removeAll(keepingCapacity: true)
        pendingBottomRows = frame.height - bandEnd
        let copyBytes = width * 4
        for row in bandEnd..<frame.height {
            let start = frame.rowStart(row)
            pendingBottom.append(contentsOf: frame.pixels[start..<(start + copyBytes)])
        }
    }

    // MARK: - 纯函数核心（可独立测试）

    /// 整帧的行签名（`append(_:)` 内部同款）。暴露成静态纯函数是给采集管线用的：
    /// 后台队列先算一次，既做「与上一帧相同就丢弃」的节流判定（`isDuplicate`），
    /// 算好的结果又可原样传给 `append(_:signatures:)` —— 一帧只算一次。
    static func signatures(of frame: ScrollFrame, config: Config = Config()) -> [[Float]] {
        rowSignatures(
            pixels: frame.pixels,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            hashWidth: config.hashWidth
        )
    }

    /// 「这一帧画面与上一帧相同」的快速判定：行签名逐行全等。
    /// 连续流采集用它在进拼接器之前丢掉静止帧 —— 签名是模糊指纹，
    /// 全等意味着画面没有肉眼可见的变化，喂给拼接器也只会得到 `.unchanged`。
    static func isDuplicate(_ signatures: [[Float]], of previous: [[Float]]?) -> Bool {
        previous == signatures
    }

    /// 行签名：每行分 `hashWidth` 个桶，桶内最多采 4 个像素取灰度均值。
    /// 签名是模糊指纹，不需要精确均值 —— 采样把成本压到与图像宽度无关。
    static func rowSignatures(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        hashWidth: Int
    ) -> [[Float]] {
        let buckets = max(1, min(hashWidth, width))
        var result: [[Float]] = []
        result.reserveCapacity(height)

        pixels.withUnsafeBufferPointer { buf in
            for row in 0..<height {
                let base = row * bytesPerRow
                var sig = [Float](repeating: 0, count: buckets)
                for b in 0..<buckets {
                    let x0 = b * width / buckets
                    let x1 = (b + 1) * width / buckets
                    let span = max(1, x1 - x0)
                    let samples = min(4, span)
                    var sum: Float = 0
                    for s in 0..<samples {
                        let x = x0 + s * span / samples
                        let i = base + x * 4
                        sum += 0.299 * Float(buf[i])
                             + 0.587 * Float(buf[i + 1])
                             + 0.114 * Float(buf[i + 2])
                    }
                    sig[b] = sum / Float(samples)
                }
                result.append(sig)
            }
        }
        return result
    }

    /// 两个行签名的平均绝对差（0–255 刻度）。
    static func meanAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return .infinity }
        var total: Float = 0
        for i in 0..<n { total += abs(a[i] - b[i]) }
        return total / Float(n)
    }

    /// 在帧的中段里为「拼接结果尾部 anchor」找最佳对齐。
    ///
    /// - Parameter candidates: 候选行号 p 的范围 —— p 表示「拼接结果最后一行」
    ///   对应帧的第 p 行；锚区映射到帧的 [p-n+1, p]。
    /// - Returns: 最佳 p；所有候选的代价都超过阈值时返回 nil。
    ///   并列（代价差 ≤ tieEpsilon）时取最大的 p，即最小滚动量 ——
    ///   纯色区域里所有对齐代价都近似为零，保守选择的接缝仍然无缝。
    static func findAlignment(
        anchor: [[Float]],
        frame: [[Float]],
        candidates: ClosedRange<Int>,
        maxMeanDiff: Float,
        tieEpsilon: Float
    ) -> Int? {
        let n = anchor.count
        guard n > 0,
              candidates.lowerBound - n + 1 >= 0,
              candidates.upperBound < frame.count else { return nil }

        var costs: [(p: Int, cost: Float)] = []
        var bestCost = Float.infinity
        for p in candidates {
            var total: Float = 0
            for i in 0..<n {
                total += meanAbsDiff(anchor[i], frame[p - n + 1 + i])
            }
            let cost = total / Float(n)
            costs.append((p, cost))
            if cost < bestCost { bestCost = cost }
        }

        guard bestCost <= maxMeanDiff else { return nil }
        var chosen = -1
        for (p, cost) in costs where cost <= bestCost + tieEpsilon && p > chosen {
            chosen = p
        }
        return chosen
    }
}

// MARK: - CVPixelBuffer 桥（SCStream 连续流路径）

extension ScrollFrame {
    /// 把 SCStream 送来的 BGRA `CVPixelBuffer` 规格化成紧凑 RGBA8 缓冲。
    /// 一次 `vImagePermuteChannels` 同时完成两件事：BGRA→RGBA 通道重排，
    /// 以及去掉 CoreVideo 的行尾对齐填充（源 bytesPerRow → 紧凑 width*4）——
    /// SIMD 加速、内存带宽级吞吐，比逐像素手工换序快一个量级。
    init?(pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let dstBPR = w * 4
        var pixels = [UInt8](repeating: 0, count: dstBPR * h)
        var src = vImage_Buffer(
            data: base,
            height: vImagePixelCount(h),
            width: vImagePixelCount(w),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        let permuted = pixels.withUnsafeMutableBytes { dst -> Bool in
            var dest = vImage_Buffer(
                data: dst.baseAddress,
                height: vImagePixelCount(h),
                width: vImagePixelCount(w),
                rowBytes: dstBPR
            )
            let map: [UInt8] = [2, 1, 0, 3]   // BGRA → RGBA
            return vImagePermuteChannels_ARGB8888(&src, &dest, map, vImage_Flags(kvImageNoFlags))
                == kvImageNoError
        }
        guard permuted else { return nil }

        self.init(width: w, height: h, bytesPerRow: dstBPR, pixels: pixels)
    }
}

// MARK: - CGImage 桥

extension ScrollFrame {
    /// 把捕获到的 CGImage 规格化成紧凑 RGBA8 缓冲（sRGB，行 0 在顶部）。
    init?(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let bpr = w * 4
        var buffer = [UInt8](repeating: 0, count: bpr * h)
        let drawn = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        self.init(width: w, height: h, bytesPerRow: bpr, pixels: buffer)
    }
}
