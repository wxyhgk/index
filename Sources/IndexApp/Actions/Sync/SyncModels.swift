import Foundation

/// 同步进度（phase + 当前/总数）。
struct SyncProgress: Equatable {
    var phase: String
    var current: Int
    var total: Int

    var fraction: Double {
        total > 0 ? Double(current) / Double(total) : 0
    }
}

/// 同步结果汇总。
struct SyncResult: Equatable {
    var filesUploaded: Int = 0
    var filesDownloaded: Int = 0
    var filesSkipped: Int = 0
    var errors: [String] = []
    var importReport: String?

    var summary: String {
        var parts: [String] = []
        if filesUploaded > 0 { parts.append("上传 \(filesUploaded) 个文件") }
        if filesDownloaded > 0 { parts.append("下载 \(filesDownloaded) 个文件") }
        if filesSkipped > 0 { parts.append("跳过 \(filesSkipped) 个") }
        if let report = importReport { parts.append(report) }
        let base = parts.isEmpty ? "已是最新" : parts.joined(separator: "，")
        if errors.isEmpty { return base }
        return "\(base)，\(errors.count) 个错误"
    }
}
