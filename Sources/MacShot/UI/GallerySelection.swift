import Combine
import Foundation

// MARK: - 图库选中状态
//
// 只装「选中了哪几张」这一件事：单选 / ⌘toggle / ⇧区间 / ⌘A 全选 / Esc 收拢，
// 外加一个由网格上唯一确认框消费的待删除队列。视图与键盘导航共享同一个单例。

@MainActor
final class GallerySelection: ObservableObject {
    static let shared = GallerySelection()

    /// 选中集合。空 = 未选；1 张 = 单选；多张 = 批量语义。
    @Published private(set) var selectedIDs: Set<Int64> = []
    /// ⇧ 范围选择的锚点：普通点击 / ⌘点击把锚点移到落点，⇧点击保持不动。
    @Published private(set) var anchorID: Int64?
    /// 主选中：单选时的那张 / 多选时最后操作的那张。
    /// inspector 展示、键盘走格起点、Quick Look 定位都以它为准。
    @Published private(set) var primaryID: Int64?
    /// 待确认删除的截图 ID（展示顺序）。键盘 ⌘⌫、右键菜单、多选面板都写这里，
    /// 由 GalleryGrid 上唯一的 confirmationDialog 消费 —— 确认框只有一套。
    @Published var pendingDeleteIDs: [Int64]?
    /// F2 只发“重命名哪一张”的意图；具体输入框由网格统一呈现。
    @Published var pendingRenameID: Int64?

    // 「窗口处于图库还是编辑器模式」不在这里 —— 那不是选中状态，
    // 见 `GalleryWindowMode`（存 ID 不存快照的单窗口双模式模型）。

    var isMultiple: Bool { selectedIDs.count > 1 }

    func isSelected(_ id: Int64?) -> Bool {
        id.map { selectedIDs.contains($0) } ?? false
    }

    /// 单选（清空集合）。定位类场景（时间线 / 相似 / 开窗定位 / Quick Look 翻页）
    /// 语义 = 清空后单选，全走这里。
    func select(only id: Int64?) {
        selectedIDs = id.map { [$0] } ?? []
        anchorID = id
        primaryID = id
    }

    /// ⌘点击：toggle 该张的选中态，锚点移到落点。
    func toggle(_ id: Int64) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if primaryID == id { primaryID = selectedIDs.first }
        } else {
            selectedIDs.insert(id)
            primaryID = id
        }
        anchorID = id
    }

    /// ⇧点击 / ⇧方向键：选中锚点到目标的**全局顺序**区间（跨分组连续）。
    /// `orderedIDs` 是当前列表的展示顺序；锚点失效时退化为单选。
    func selectRange(to id: Int64, in orderedIDs: [Int64]) {
        guard let anchorID,
              let a = orderedIDs.firstIndex(of: anchorID),
              let b = orderedIDs.firstIndex(of: id)
        else {
            select(only: id)
            return
        }
        selectedIDs = Set(orderedIDs[min(a, b)...max(a, b)])
        primaryID = id
    }

    /// ⌘A：全选当前列表。主选中还在列表里就不跳。
    func selectAll(_ orderedIDs: [Int64]) {
        guard !orderedIDs.isEmpty else { return }
        selectedIDs = Set(orderedIDs)
        anchorID = orderedIDs.first
        if primaryID.map({ selectedIDs.contains($0) }) != true {
            primaryID = orderedIDs.last
        }
    }

    /// Esc：多选收拢回主选中那一张。
    func collapseToPrimary() {
        select(only: primaryID ?? selectedIDs.first)
    }
}
