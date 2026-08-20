import AVFoundation
import CoreGraphics
import Foundation

/// 一个操作步骤的时间区间（秒，相对视频起点）。
///
/// 结构约定：步骤 = 一次画面变化 + 变化结束后的静止期。
/// `representativeTime` 落在静止期内 —— 抽到的代表帧包含操作完成后的
/// 结果画面，而不是动作进行中的中间帧。
struct DetectedStep: Equatable, Sendable {
    let start: Double
    let end: Double
    let representativeTime: Double
    /// 触发该步骤的点击位置（AppKit 全局坐标，左下原点，点）。
    /// 初始状态步骤和帧差回退路径为 nil。
    let clickLocation: CGPoint?
}

/// 一次被记录的鼠标点击：净录制时刻 + 全局位置（AppKit 坐标，左下原点，点）。
struct ClickEvent: Equatable, Sendable {
    let time: Double
    let location: CGPoint
}

enum StepDetectionError: Error, LocalizedError {
    case noVideo

    var errorDescription: String? {
        switch self {
        case .noVideo:
            return "视频里没有可用画面"
        }
    }
}

/// 把录屏切成「操作步骤」，纯计算，不依赖 AI。
///
/// 首选**鼠标点击**切分：录制期间 `MouseClickTracker` 记下每次点击的净录制时间，
/// 每个点击就是一个步骤的起点（双击/三击合并），代表帧取步骤区间中点。
/// 点击是用户动作的直接信号，语义精确、不需要调阈值。
///
/// 没有点击记录时（纯键盘操作、或老视频）回退**帧差**两遍法：
/// 1. 分析遍：按 5fps 抽低分辨率灰度帧（宽 160px），算相邻帧平均像素差；
/// 2. 切分：静止段（差异低于安静阈值）之后紧跟的画面变化，就是一个新步骤的起点；
/// 3. 代表帧时间 = 该步骤尾部静止期的中点。
///
/// 光标已经烧进 mp4（`showsCursor = true`），画面里天然能看到每次点击的位置。
enum StepDetector {

    /// 分析遍抽帧参数（帧差回退路径用）。
    static let analysisWidth: CGFloat = 160
    static let analysisFrameInterval: Double = 0.2 // 5fps

    /// 相邻帧平均灰度差（0...1）低于该值视为「画面静止」。
    /// 0.01 ≈ 2.55/255，远高于视频压缩噪声，低于任何真实 UI 变化。
    static let quietThreshold: Double = 0.01

    /// 静止段短于该时长不视为步骤边界（单帧噪声防抖）。
    static let minQuietDuration: Double = 0.3

    /// 两个步骤边界的最小间隔；短于该值的合并，防止连续快速操作被切碎。
    static let minStepDuration: Double = 0.5

    /// 点击防抖：短于该间隔的连续点击视为一次操作（双击/三击合并）。
    static let clickDebounce: Double = 0.4

    /// 切出整段视频的步骤序列。有点击记录走点击切分，否则回退帧差。
    static func detect(videoURL: URL, clicks: [ClickEvent] = []) async throws -> [DetectedStep] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw StepDetectionError.noVideo }

        if !clicks.isEmpty {
            let steps = detectSteps(clicks: clicks, videoDuration: duration)
            if !steps.isEmpty { return steps }
        }

        let frameCount = max(2, Int(duration / analysisFrameInterval) + 1)
        let images = try await extractAnalysisFrames(asset: asset, count: frameCount)
        let diffs = frameDiffs(images: images)
        return detectSteps(
            diffs: diffs,
            frameInterval: analysisFrameInterval,
            videoDuration: duration,
            quietThreshold: quietThreshold,
            minQuietDuration: minQuietDuration,
            minStepDuration: minStepDuration
        )
    }

    // MARK: - 点击切分（纯计算）

    /// 点击事件序列 → 步骤区间。每个点击 = 一个步骤的起点（带点击位置，
    /// 供代表帧高亮）；首个点击距开头足够远时，开头单独成「初始状态」步骤
    /// （无点击位置）。代表帧取区间中点 —— 点击触发的操作通常在中点前完成。
    static func detectSteps(
        clicks: [ClickEvent],
        videoDuration: Double,
        debounce: Double = clickDebounce
    ) -> [DetectedStep] {
        // 双击/三击合并：间隔 < debounce 的连续点击只留第一个（位置也取第一个）。
        var merged: [ClickEvent] = []
        for click in clicks.sorted(by: { $0.time < $1.time })
        where click.time >= 0 && click.time < videoDuration {
            if let last = merged.last, click.time - last.time < debounce { continue }
            merged.append(click)
        }

        // 首个点击距开头 < minStepDuration 时不另设初始状态步骤（开头就是操作）。
        let boundaries: [ClickEvent?]
        if let first = merged.first, first.time >= minStepDuration {
            boundaries = [nil] + merged
        } else {
            boundaries = merged
        }
        guard !boundaries.isEmpty else { return [] }

        return boundaries.enumerated().map { index, click in
            let start = click?.time ?? 0
            let end = index + 1 < boundaries.count ? (boundaries[index + 1]?.time ?? videoDuration) : videoDuration
            return DetectedStep(
                start: start,
                end: end,
                representativeTime: (start + end) / 2,
                clickLocation: click?.location
            )
        }
    }

    // MARK: - 纯计算（可脱离 AVFoundation 测试）

    /// 相邻帧平均灰度差序列。`diffs[i]` = 第 i 帧与第 i+1 帧的差异，0...1。
    static func frameDiffs(images: [CGImage]) -> [Double] {
        guard images.count >= 2 else { return [] }
        let buffers = images.map { grayscalePixels($0) }
        var diffs: [Double] = []
        diffs.reserveCapacity(buffers.count - 1)
        for (current, next) in zip(buffers, buffers.dropFirst()) {
            diffs.append(meanAbsoluteDifference(current, next))
        }
        return diffs
    }

    /// 差异序列 → 步骤区间。
    ///
    /// `diffs[i]` 对应「第 i 帧 → 第 i+1 帧」的过渡，第 i 帧时刻 = i * frameInterval。
    /// 步骤边界 = 足够长的静止段之后第一个变化帧的时刻。
    static func detectSteps(
        diffs: [Double],
        frameInterval: Double,
        videoDuration: Double,
        quietThreshold: Double = quietThreshold,
        minQuietDuration: Double = minQuietDuration,
        minStepDuration: Double = minStepDuration
    ) -> [DetectedStep] {
        // 1. 找出所有静止段 [start, end)（diffs 下标空间）。
        var quietRuns: [(start: Int, end: Int)] = []
        var i = 0
        while i < diffs.count {
            if diffs[i] >= quietThreshold {
                i += 1
                continue
            }
            let runStart = i
            while i < diffs.count, diffs[i] < quietThreshold { i += 1 }
            quietRuns.append((runStart, i))
        }

        // 2. 步骤边界：静止段（足够长）之后紧跟变化段，且距上一边界足够远。
        //    边界同时记录它前面的静止段 —— 那是上一个步骤的尾部静止期。
        var boundaries: [(time: Double, quietBefore: (start: Int, end: Int)?)] = [(0, nil)]
        for run in quietRuns {
            guard run.end < diffs.count else { continue } // 尾部静止不产生新步骤
            let quietDuration = Double(run.end - run.start) * frameInterval
            guard quietDuration >= minQuietDuration else { continue }
            let candidate = Double(run.end) * frameInterval
            guard candidate - boundaries[boundaries.count - 1].time >= minStepDuration else { continue }
            boundaries.append((candidate, (run.start, run.end)))
        }

        // 3. 组装步骤：[boundary_i, boundary_{i+1})，代表帧取尾部静止期中点。
        let trailingRun = quietRuns.last
        var steps: [DetectedStep] = []
        steps.reserveCapacity(boundaries.count)
        for (index, boundary) in boundaries.enumerated() {
            let start = boundary.time
            let end = index + 1 < boundaries.count
                ? boundaries[index + 1].time
                : videoDuration

            let representative: Double
            if index + 1 < boundaries.count, let run = boundaries[index + 1].quietBefore {
                representative = Double(run.start + run.end) / 2 * frameInterval
            } else if let run = trailingRun, Double(run.start) * frameInterval >= start {
                representative = Double(run.start + run.end) / 2 * frameInterval
            } else {
                // 视频在变化中结束，没有尾部静止期：取步骤末尾。
                representative = max(start, end - 0.05)
            }
            steps.append(DetectedStep(
                start: start,
                end: end,
                representativeTime: representative,
                clickLocation: nil
            ))
        }
        return steps
    }

    // MARK: - 分析遍抽帧

    /// 按 5fps 抽低分辨率帧。个别时间点取帧失败用上一帧补位（差异记 0，
    /// 视为静止 —— 对切分是保守方向）。
    private static func extractAnalysisFrames(asset: AVURLAsset, count: Int) async throws -> [CGImage] {
        let tracks = try await asset.load(.tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else {
            throw StepDetectionError.noVideo
        }
        let natural = (try await track.load(.naturalSize)).applying(try await track.load(.preferredTransform))
        let scale = analysisWidth / abs(natural.width)
        let size = CGSize(
            width: analysisWidth,
            height: max(1, (abs(natural.height) * scale).rounded())
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        // 分析遍只求大致时间对齐，放宽容差提高成功率。
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        var images: [CGImage] = []
        images.reserveCapacity(count)
        var last: CGImage?
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) * analysisFrameInterval, preferredTimescale: 5)
            if let image = try? await generator.image(at: time).image {
                last = image
            }
            if let image = last { images.append(image) }
        }
        guard !images.isEmpty else { throw StepDetectionError.noVideo }
        return images
    }

    // MARK: - 灰度差异

    /// 把帧画进 8bit 灰度缓冲。分析帧尺寸很小（160px 宽），直接拷贝像素。
    private static func grayscalePixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total: Double = 0
        for index in 0..<a.count {
            total += Double(abs(Int(a[index]) - Int(b[index])))
        }
        return total / Double(a.count) / 255.0
    }
}
