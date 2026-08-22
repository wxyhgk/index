import AVFoundation
import CoreGraphics
import Foundation

/// 录屏 → 图文步骤指南的编排：切步骤 → 抽代表帧 → 配文 → 导出。
///
/// AI 配文默认关闭：不传 executor 时每步配文就是「步骤 N」。
/// 后续开启 = 传入 `SelectionAIAssembly.makeExecutor(intelligence:)`，
/// 走 `.explain` 任务 + 自定义 instruction，单步失败回退「步骤 N」，
/// 不会让整个指南失败。
enum StepGuideGenerator {

    /// AI 配文 instruction：让模型只输出一步的操作描述，不解释、不分段。
    static let stepCaptionInstruction =
        "这是从一段操作录屏中截取的一步画面。请用一句中文描述这一步在做什么操作，" +
        "只输出这一句话，不要编号、不要分段、不要解释。"

    /// `region` 是录制选区（AppKit 全局坐标，点），`scale` 是选区所在显示器的
    /// 缩放比 —— 两者用于把点击的全局点坐标换算到代表帧的像素坐标画高亮圈。
    static func generate(
        videoURL: URL,
        clicks: [ClickEvent] = [],
        region: CGRect? = nil,
        scale: CGFloat = 1,
        executor: SelectionAIExecutor? = nil
    ) async throws -> StepGuide {
        let steps = try await StepDetector.detect(videoURL: videoURL, clicks: clicks)
        let frames = try await extractRepresentativeFrames(
            videoURL: videoURL,
            times: steps.map(\.representativeTime)
        )
        guard frames.count == steps.count else { throw StepGuideError.noSteps }

        var guideSteps: [StepGuideStep] = []
        guideSteps.reserveCapacity(steps.count)
        for index in steps.indices {
            var image = frames[index]
            // 有点击位置且知道选区时，在代表帧上画高亮圈。
            if let location = steps[index].clickLocation, let region {
                image = ClickHighlightRenderer.highlight(
                    image: image,
                    clickLocation: location,
                    region: region,
                    scale: scale
                )
            }
            let caption = await caption(
                for: index + 1,
                image: image,
                executor: executor
            )
            guideSteps.append(StepGuideStep(image: image, caption: caption))
        }

        return try StepGuideExporter.export(
            steps: guideSteps,
            sourceName: videoURL.lastPathComponent,
            destination: videoURL.deletingLastPathComponent()
        )
    }

    // MARK: - 代表帧

    /// 全分辨率抽代表帧。个别时间点失败用上一帧补位；连续失败到没有可用帧才抛错。
    private static func extractRepresentativeFrames(
        videoURL: URL,
        times: [Double]
    ) async throws -> [CGImage] {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw StepGuideError.noSteps
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        var frames: [CGImage] = []
        frames.reserveCapacity(times.count)
        var last: CGImage?
        for time in times {
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                last = image
            }
            if let image = last { frames.append(image) }
        }
        return frames
    }

    // MARK: - 配文

    private static func caption(
        for number: Int,
        image: CGImage,
        executor: SelectionAIExecutor?
    ) async -> String {
        let fallback = "步骤 \(number)"
        guard let executor else { return fallback }
        do {
            let request = SelectionAIRequest(
                task: .explain,
                input: SelectionAIInput(image: image),
                instruction: stepCaptionInstruction
            )
            let response = try await executor.execute(request)
            guard case .explanation(let markdown) = response.result else { return fallback }
            let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : text
        } catch {
            NSLog("[Index] 步骤 \(number) AI 配文失败，回退默认文案: \(error)")
            return fallback
        }
    }
}
