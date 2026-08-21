import Foundation
import Vision
import CoreGraphics

/// 一处检测到的敏感内容。
///
/// `rect` 是**图像像素坐标、左上原点** —— 和图层（`Layer.rect`）同一空间，
/// 拿到就能直接生成马赛克层。`preview` 是脱敏后的摘要（如 "ab***@gmail.com"），
/// 只用于界面提示，**绝不进全文索引**。
struct SensitiveRegion: Codable, Equatable {
    var rect: CGRect
    var kind: String
    var preview: String
}

/// 敏感内容检测：文字（邮箱 / 各类密钥 / 银行卡 / 手机号 / IP）+ 人脸。
///
/// 全部走系统 Vision 框架，零下载、零联网。它只负责「找出来」，
/// 落库由 `SensitiveContentProcessor` 决定，打码由界面层决定。
struct SensitiveContentDetector {

    func detect(in image: CGImage) async -> [SensitiveRegion] {
        async let recognizedText = VisionTextRecognition().recognize(in: image)
        async let faces = detectFaces(in: image)
        let text = sensitiveRegions(in: await recognizedText)
        return await text + faces
    }

    func detect(in image: CGImage, recognizedText: [VisionTextLine]) async -> [SensitiveRegion] {
        async let faces = detectFaces(in: image)
        let text = sensitiveRegions(in: recognizedText)
        return await text + faces
    }

    func sensitiveRegions(in lines: [VisionTextLine]) -> [SensitiveRegion] {
        var regions: [SensitiveRegion] = []
        for line in lines {
            var seen: Set<String> = []
            for candidate in line.candidates {
                for (kind, preview) in Self.matches(in: candidate) {
                    let identity = "\(kind)\u{0}\(preview)"
                    guard seen.insert(identity).inserted else { continue }
                    regions.append(SensitiveRegion(rect: line.rect, kind: kind, preview: preview))
                }
            }
        }
        return regions
    }

    // MARK: - 文本规则

    /// 一条识别规则：正则命中后（可选）再过一道校验，命中则按 `mask` 生成摘要。
    private struct Rule {
        let kind: String
        let pattern: String
        var validate: (String) -> Bool = { _ in true }
        let mask: (String) -> String
    }

    /// 顺序即优先级：具体的密钥格式在前，宽泛的数字规则在后。
    /// 银行卡 / 手机号用 `(?<!\d)…(?!\d)` 保证不落在更长的数字串中间。
    private static let rules: [Rule] = [
        Rule(
            kind: "邮箱",
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            mask: maskEmail
        ),
        Rule(
            kind: "AWS 密钥",
            pattern: #"AKIA[0-9A-Z]{16}"#,
            mask: maskSecret
        ),
        Rule(
            kind: "JWT 令牌",
            pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            mask: maskSecret
        ),
        Rule(
            kind: "GitHub 令牌",
            pattern: #"gh[pousr]_[A-Za-z0-9]{20,}"#,
            mask: maskSecret
        ),
        Rule(
            kind: "API 密钥",
            pattern: #"sk-[A-Za-z0-9_-]{20,}"#,
            mask: maskSecret
        ),
        Rule(
            kind: "银行卡号",
            pattern: #"(?<!\d)\d{13,19}(?!\d)"#,
            validate: luhnValid,
            mask: { card in "**** " + String(card.suffix(4)) }
        ),
        Rule(
            kind: "手机号",
            pattern: #"(?<!\d)1[3-9]\d{9}(?!\d)"#,
            mask: { phone in String(phone.prefix(3)) + "****" + String(phone.suffix(4)) }
        ),
        Rule(
            kind: "IP 地址",
            pattern: #"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)"#,
            validate: { ip in ip.split(separator: ".").allSatisfy { UInt8($0) != nil } },
            mask: { ip in
                let parts = ip.split(separator: ".")
                return "\(parts[0]).*.*.\(parts[3])"
            }
        )
    ]

    /// 对一段识别文本跑全部规则，返回命中的 (种类, 脱敏摘要)。
    /// 同一段文字里同种类的重复命中只记一次 —— 框是整个 observation，重复没有意义。
    private static func matches(in text: String) -> [(kind: String, preview: String)] {
        var results: [(kind: String, preview: String)] = []
        let range = NSRange(text.startIndex..., in: text)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                let hit = String(text[r])
                guard rule.validate(hit) else { continue }
                let preview = rule.mask(hit)
                if !results.contains(where: { $0.kind == rule.kind && $0.preview == preview }) {
                    results.append((rule.kind, preview))
                }
            }
        }
        return results
    }

    // MARK: - 人脸

    private func detectFaces(in image: CGImage) async -> [SensitiveRegion] {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        return await withCheckedContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNFaceObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                let regions = observations.map { observation -> SensitiveRegion in
                    let bb = observation.boundingBox
                    let rect = CGRect(
                        x: bb.minX * width,
                        y: (1 - bb.maxY) * height,
                        width: bb.width * width,
                        height: bb.height * height
                    )
                    return SensitiveRegion(rect: rect, kind: "人脸", preview: "人脸")
                }
                continuation.resume(returning: regions)
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[Index] 人脸检测失败: \(error)")
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - 脱敏与校验

    private static func maskEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return maskSecret(email) }
        let local = email[..<at]
        let domain = email[at...]
        return String(local.prefix(2)) + "***" + domain
    }

    private static func maskSecret(_ secret: String) -> String {
        String(secret.prefix(4)) + "***"
    }

    /// Luhn 校验：过滤掉纯粹的长数字（订单号、时间戳）误报。
    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        for (index, char) in digits.reversed().enumerated() {
            guard let d = char.wholeNumberValue else { return false }
            var value = d
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}
