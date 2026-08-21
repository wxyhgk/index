import XCTest
@testable import IndexApp

/// 模态面板落点的安全网。
///
/// 真正的 bug 是「弹到了别的屏」，那部分靠 `targetScreen` 的优先级解决、需要真实
/// 多屏环境才能验；这里锁住的是另一半 —— 算出来的落点必须**留在目标屏可见区域内**。
/// 用户的三屏里有一块 720×1280 的竖屏，比存盘面板（实测 800×747）还窄，
/// 天真地居中会让面板挂出去半截。
final class PanelPlacementTests: XCTestCase {

    /// 实测的存盘面板尺寸。
    private let panelSize = CGSize(width: 800, height: 747)

    /// 宽屏：水平居中，垂直把空隙的三分之一留在上面。
    func testCentersHorizontallyAndSitsAboveCenter() {
        let visible = CGRect(x: 0, y: 61, width: 1920, height: 994)

        let origin = PanelPlacement.origin(panelSize: panelSize, in: visible)

        XCTAssertEqual(origin.x, (1920 - 800) / 2, accuracy: 0.5, "水平应居中")
        // 空隙 = 994 - 747 = 247，其中 1/3 留在面板上方。
        XCTAssertEqual(origin.y, 61 + 247 - 247 / 3, accuracy: 0.5)
        XCTAssertGreaterThan(origin.y, visible.midY - panelSize.height / 2, "应偏上而非正中")
    }

    /// 竖屏比面板窄：不许出现负的左边距，宁可贴左也不能挂出屏外。
    func testClampsOnScreenNarrowerThanPanel() {
        let visible = CGRect(x: -720, y: -200, width: 720, height: 1255)

        let origin = PanelPlacement.origin(panelSize: panelSize, in: visible)

        XCTAssertEqual(origin.x, visible.minX, accuracy: 0.5, "屏比面板窄时贴左边")
        XCTAssertGreaterThanOrEqual(origin.y, visible.minY)
    }

    /// 屏比面板矮：底边不许沉到可见区域以下（否则「存储」按钮点不到）。
    func testClampsOnScreenShorterThanPanel() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 600)

        let origin = PanelPlacement.origin(panelSize: panelSize, in: visible)

        XCTAssertEqual(origin.y, visible.minY, accuracy: 0.5)
    }

    /// 落点必须是**目标屏**的坐标，而不是主屏原点附近的数 ——
    /// 这条正是「弹错屏」在纯函数层面的体现。
    func testOriginLandsInsideTheGivenScreen() {
        let secondary = CGRect(x: 130, y: -945, width: 1680, height: 920)

        let origin = PanelPlacement.origin(panelSize: panelSize, in: secondary)

        XCTAssertTrue(
            secondary.contains(CGRect(origin: origin, size: panelSize)),
            "面板应整体落在 \(secondary) 内，实得 \(origin)"
        )
    }
}
