import Foundation

/// 候选分页的纯状态；数字键和平台面板共享同一套绝对下标换算。
public struct CandidatePagination: Equatable, Sendable {
    public let pageSize: Int
    public private(set) var itemCount = 0
    public private(set) var selectedIndex = 0

    public init(pageSize: Int = 9) {
        self.pageSize = max(1, pageSize)
    }

    public var pageCount: Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + pageSize - 1) / pageSize
    }

    public var pageIndex: Int {
        guard itemCount > 0 else { return 0 }
        return selectedIndex / pageSize
    }

    public var visibleRange: Range<Int> {
        let start = min(pageIndex * pageSize, itemCount)
        return start..<min(start + pageSize, itemCount)
    }

    public mutating func reset(itemCount: Int) {
        self.itemCount = max(0, itemCount)
        selectedIndex = 0
    }

    public mutating func moveSelection(by delta: Int) {
        guard itemCount > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), itemCount - 1)
    }

    public mutating func movePage(by delta: Int) {
        guard pageCount > 0 else { return }
        let targetPage = min(max(0, pageIndex + delta), pageCount - 1)
        selectedIndex = min(targetPage * pageSize, itemCount - 1)
    }

    /// 数字使用 1-based 语义，返回当前页对应的绝对候选下标。
    public func absoluteIndex(forNumber number: Int) -> Int? {
        guard (1...pageSize).contains(number) else { return nil }
        let index = visibleRange.lowerBound + number - 1
        return index < visibleRange.upperBound ? index : nil
    }
}
