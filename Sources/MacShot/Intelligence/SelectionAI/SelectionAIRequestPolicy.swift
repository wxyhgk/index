import Foundation

/// 不同任务对细小文字的容忍度不同。策略限制上传像素与 PNG 体积，
/// 同时保留公式、表格所需的更高分辨率；所有阈值只会缩小图片，不会放大。
struct SelectionAIRequestPolicy: Equatable, Sendable {
    let maxLongEdge: Int
    let maxPixelCount: Int
    let minimumLongEdge: Int
    let maxEncodedBytes: Int
    let maxOutputTokens: Int

    static func policy(for task: SelectionAITaskKind) -> Self {
        let mebibyte = 1024 * 1024
        switch task {
        case .explain:
            return Self(
                maxLongEdge: 2_048,
                maxPixelCount: 3_000_000,
                minimumLongEdge: 1_024,
                maxEncodedBytes: 3 * mebibyte,
                maxOutputTokens: 2_048
            )
        case .translate:
            return Self(
                maxLongEdge: 2_560,
                maxPixelCount: 4_000_000,
                minimumLongEdge: 1_600,
                maxEncodedBytes: 4 * mebibyte,
                maxOutputTokens: 2_048
            )
        case .formulaToLaTeX:
            return Self(
                maxLongEdge: 3_200,
                maxPixelCount: 6_000_000,
                minimumLongEdge: 2_000,
                maxEncodedBytes: 6 * mebibyte,
                maxOutputTokens: 1_024
            )
        case .extractTable:
            return Self(
                maxLongEdge: 4_096,
                maxPixelCount: 8_000_000,
                minimumLongEdge: 2_560,
                maxEncodedBytes: 8 * mebibyte,
                maxOutputTokens: 4_096
            )
        }
    }
}
