import Foundation

// MARK: - 图库中栏的支撑类型
//
// 从 `GalleryGrid.swift` 拆出：这一组顶层类型不依赖视图实例，
// 是「时间分组、快照键、视觉预算」的纯数据与纯函数，
// 单独成文件后可以脱离 SwiftUI 视图直接单测。

/// 中栏的两种外观：标准（带底部悬浮工具条）与图库面板（侧栏内嵌，不画工具条）。
enum GalleryGridChrome {
    case standard
    case libraryPanel

    var showsFloatingToolbar: Bool { self == .standard }
}

/// 逐卡合成效果的硬预算。即使用户以前打开过开关，也不能让效果随着整页 300 张
/// 无限扩张；超过约三屏后直接回到普通卡片，交互与内容保持不变。
enum GalleryVisualBudget {
    static let maximumScrollDepthCards = 60

    static func allowsScrollDepth(isEnabled: Bool, cardCount: Int) -> Bool {
        isEnabled && cardCount > 0 && cardCount <= maximumScrollDepthCards
    }
}

/// 一个时间段的截图。分组在 shots 变化时算一次，不在 body 里逐帧分组。
struct ShotSection: Identifiable {
    let id: String
    let title: String
    var shots: [Shot]

    /// 按拍摄时间分成 今天 / 昨天 / 本周 / 本月 / 更早，空段不出现。
    /// shots 已按时间降序，段内顺序自然保持。
    static func group(_ shots: [Shot], calendar: Calendar = .current) -> [ShotSection] {
        let now = Date()
        var buckets: [String: [Shot]] = [:]
        for shot in shots {
            let date = shot.capturedAt
            let key: String
            if calendar.isDateInToday(date) {
                key = "今天"
            } else if calendar.isDateInYesterday(date) {
                key = "昨天"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                key = "本周"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .month) {
                key = "本月"
            } else {
                key = "更早"
            }
            buckets[key, default: []].append(shot)
        }
        return ["今天", "昨天", "本周", "本月", "更早"].compactMap { title in
            buckets[title].map { ShotSection(id: title, title: title, shots: $0) }
        }
    }

    /// 分页追加：只对新 shots 做分组，合并到已有 sections 尾部。
    /// 新 shots 的时间一定比已有更旧（时间降序），所以只会落在已有段尾部或新段。
    static func mergeAppend(existing: [ShotSection], newShots: [Shot], calendar: Calendar = .current) -> [ShotSection] {
        guard !newShots.isEmpty else { return existing }
        let newSections = group(newShots, calendar: calendar)
        var result = existing
        for newSection in newSections {
            if let idx = result.firstIndex(where: { $0.id == newSection.id }) {
                result[idx].shots.append(contentsOf: newSection.shots)
            } else {
                result.append(newSection)
            }
        }
        return result
    }
}

/// `.task(id:)` 的廉价键。库存内容变更另有 `libraryDidChange` 强制刷新；分页只会
/// 追加，因此数量/尾 ID 足够识别。避免每次选中或悬停导致 body 重算时都重新构造、
/// 哈希数千个 ID 的数组。
struct GalleryGridSnapshotKey: Equatable {
    let sessionGeneration: Int
    let presentationRevision: Int
    let count: Int
    let firstID: Int64?
    let lastID: Int64?

    init(sessionGeneration: Int, presentationRevision: Int, shots: [Shot]) {
        self.sessionGeneration = sessionGeneration
        self.presentationRevision = presentationRevision
        count = shots.count
        firstID = shots.first?.id
        lastID = shots.last?.id
    }
}

/// 元数据和它对应的可见顺序必须一起发布，否则 SwiftUI 可能在分页帧里短暂看到
/// “新卡片 + 旧元数据”。保留 ID 前缀也让下一页只查询新增后缀。
struct GalleryGridMetadataSnapshot: Equatable {
    let shotIDs: [Int64]
    let metadata: ShotPageMetadata

    static let empty = GalleryGridMetadataSnapshot(shotIDs: [], metadata: .empty)
}