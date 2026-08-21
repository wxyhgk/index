import XCTest
@testable import IndexApp

/// 图库时间分组（`ShotSection.group`）的纯逻辑单测。
///
/// 分组依赖「当前时刻」，周/月边界附近的相对日期可能落在意料外的桶里，
/// 所以断言只用**任何时刻都成立**的日期（今天/昨天/两月前），
/// 周/月桶用「找到合法日期才断言」的方式避免周末/月初 flaky。
final class ShotSectionTests: XCTestCase {

    private let calendar = Calendar.current

    private func shot(id: Int64, at date: Date) -> Shot {
        Shot(
            id: id,
            sha256: "hash-\(id)",
            capturedAt: date,
            pixelWidth: 1,
            pixelHeight: 1,
            scale: 1,
            appName: nil,
            appBundleID: nil,
            appVersion: nil,
            appBuild: nil,
            windowTitle: nil,
            sourceURL: nil,
            displayID: nil,
            displayName: nil,
            regionX: 0,
            regionY: 0,
            regionW: 1,
            regionH: 1,
            ocrText: nil
        )
    }

    /// 本周内、但不是今天也不是昨天的日期；周初（周一/二/三）可能不存在。
    private func dateInThisWeekButNotTodayOrYesterday() -> Date? {
        let now = Date()
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }
        for offset in 0..<7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            if calendar.isDateInToday(candidate) || calendar.isDateInYesterday(candidate) { continue }
            return candidate
        }
        return nil
    }

    /// 本月内、但不在本周、也不是今天/昨天的日期；月初可能不存在。
    private func dateInThisMonthButNotThisWeek() -> Date? {
        let now = Date()
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
        for offset in 0..<31 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: monthStart) else { continue }
            guard calendar.isDate(candidate, equalTo: now, toGranularity: .month) else { continue }
            if calendar.isDate(candidate, equalTo: now, toGranularity: .weekOfYear) { continue }
            if calendar.isDateInToday(candidate) || calendar.isDateInYesterday(candidate) { continue }
            return candidate
        }
        return nil
    }

    func testEmptyInputProducesNoSections() {
        XCTAssertTrue(ShotSection.group([]).isEmpty)
    }

    func testFixedOrderAndEmptyBucketsSkipped() {
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        // 两月前：必然不在本月/本周/昨天，稳定落「更早」。
        let earlier = calendar.date(byAdding: .month, value: -2, to: now)!

        let sections = ShotSection.group([
            shot(id: 1, at: now),
            shot(id: 2, at: yesterday),
            shot(id: 3, at: earlier)
        ])
        XCTAssertEqual(sections.map(\.title), ["今天", "昨天", "更早"], "固定顺序，空桶不出现")
        XCTAssertEqual(sections.map(\.shots.count), [1, 1, 1])
    }

    func testThisWeekBucket() {
        guard let thisWeek = dateInThisWeekButNotTodayOrYesterday() else { return }
        let sections = ShotSection.group([shot(id: 1, at: thisWeek)])
        XCTAssertEqual(sections.map(\.title), ["本周"])
    }

    func testThisMonthBucket() {
        guard let thisMonth = dateInThisMonthButNotThisWeek() else { return }
        let sections = ShotSection.group([shot(id: 1, at: thisMonth)])
        XCTAssertEqual(sections.map(\.title), ["本月"])
    }

    // MARK: - 顺序与身份

    func testSectionOrderIsFixedTodayFirst() {
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let earlier = calendar.date(byAdding: .month, value: -2, to: now)!
        // 故意乱序输入：更早 → 昨天 → 今天
        let sections = ShotSection.group([
            shot(id: 1, at: earlier),
            shot(id: 2, at: yesterday),
            shot(id: 3, at: now)
        ])
        XCTAssertEqual(sections.map(\.title), ["今天", "昨天", "更早"])
    }

    func testWithinSectionOrderPreserved() {
        // 用「今天 0 点 + 偏移」而不是 now 的相对值：now - 30 分钟在午夜前后
        // 会掉进昨天，段数就不稳定了。
        let startOfToday = calendar.startOfDay(for: Date())
        let first = startOfToday
        let second = calendar.date(byAdding: .minute, value: 10, to: startOfToday)!
        let sections = ShotSection.group([shot(id: 1, at: first), shot(id: 2, at: second)])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].shots.map(\.id), [1, 2], "段内保持输入顺序")
    }

    func testSectionIdentityMatchesTitle() {
        let sections = ShotSection.group([shot(id: 1, at: Date())])
        XCTAssertEqual(sections.first?.id, "今天")
        XCTAssertEqual(sections.first?.title, "今天")
    }
}