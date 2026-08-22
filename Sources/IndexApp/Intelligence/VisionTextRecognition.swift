import CoreGraphics
import Foundation
import Vision

/// 一次 Vision 文字识别得到的最小稳定结果。
///
/// `rect` 使用图像像素坐标、左上原点，与标注图层坐标一致。后处理流水线共享这份
/// 不含 Vision 对象的值，避免 OCR 与敏感信息检测各自再跑一次文字模型。
struct VisionTextLine: Sendable, Equatable {
    /// 第一项供全文 OCR 使用；后续候选让敏感检测仍能看到可能被语言纠错替换的原串。
    let candidates: [String]
    let rect: CGRect

    var text: String { candidates.first ?? "" }

    init(text: String, rect: CGRect) {
        self.init(candidates: [text], rect: rect)
    }

    init(candidates: [String], rect: CGRect) {
        self.candidates = candidates
        self.rect = rect
    }
}

struct VisionTextRecognition {
    func recognize(in image: CGImage) async -> [VisionTextLine] {
        guard image.width > 0, image.height > 0 else { return [] }
        let result: [VisionTextLine] = await withCheckedContinuation { continuation in
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            let guard_ = ContinuationGuard()
            let request = VNRecognizeTextRequest { request, error in
                guard guard_.claim() else { return }
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: [])
                    return
                }

                let lines = observations.compactMap { observation -> VisionTextLine? in
                    let candidates = observation.topCandidates(5).map(\.string)
                    guard !candidates.isEmpty else { return nil }
                    let box = observation.boundingBox
                    return VisionTextLine(
                        candidates: candidates,
                        rect: CGRect(
                            x: box.minX * width,
                            y: (1 - box.maxY) * height,
                            width: box.width * width,
                            height: box.height * height
                        )
                    )
                }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            // 第一候选保留自然语言纠错质量；敏感检测同时检查其它候选，避免密钥、
            // 卡号等非自然语言内容被第一候选"修正"后漏掉。
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                NSLog("[Index] 文字识别失败: \(error)")
                guard guard_.claim() else { return }
                continuation.resume(returning: [])
            }
        }
        return result
    }
}

/// 保证 continuation 只 resume 一次（perform 可能先调 completion 再 throw）。
private final class ContinuationGuard {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
