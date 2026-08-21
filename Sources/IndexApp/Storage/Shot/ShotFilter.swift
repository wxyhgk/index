import Foundation

/// 图库查询的稳定筛选值。它属于 Storage 查询契约，不属于某个 UI 状态容器。
enum ShotFilter: Hashable, Sendable {
    case all
    case favorites
    /// 一个 `tag` 属性行都没有的截图。
    case untagged
    /// 修订数 > 1，即确实画过标注的截图。
    case annotated
    /// 带 kind=recording 附件的录屏封面 Shot。
    case recordings
    case category(String)
    case tag(String)
    /// 按来源 App。bundleID 优先，名称只为无 bundleID 的来源兜底。
    case app(CapturedAppIdentity)
    /// 用户专题收藏集。ID 稳定，重命名不会让当前页面失效。
    case collection(Int64)
}
