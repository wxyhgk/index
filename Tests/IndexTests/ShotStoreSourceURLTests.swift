import XCTest
@testable import IndexApp

/// 同源时间线的网址归一化（`ShotStore.normalizedSourceURL`）纯逻辑单测。
///
/// 归一化只**截短**：去掉 `#fragment`、去掉尾部斜杠。
/// 「同一页面」语义下 `…/docs#intro` 和 `…/docs/` 都算 `…/docs`。
/// 该截短性质是 `relatedShots` 能用 `LIKE 'target%'` 前缀预筛的前提，
/// 所以「归一化结果必然是原串前缀」也一并断言。
@MainActor
final class ShotStoreSourceURLTests: XCTestCase {

    func testStripsFragment() {
        XCTAssertEqual(
            ShotStore.normalizedSourceURL("https://a.com/docs#intro"),
            "https://a.com/docs"
        )
    }

    func testStripsTrailingSlash() {
        XCTAssertEqual(
            ShotStore.normalizedSourceURL("https://a.com/docs/"),
            "https://a.com/docs"
        )
    }

    func testStripsFragmentAndTrailingSlashes() {
        XCTAssertEqual(
            ShotStore.normalizedSourceURL("https://a.com/docs///#x"),
            "https://a.com/docs"
        )
    }

    func testUnchangedWhenNothingToStrip() {
        XCTAssertEqual(
            ShotStore.normalizedSourceURL("https://a.com/docs"),
            "https://a.com/docs"
        )
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(ShotStore.normalizedSourceURL(""), "")
    }

    func testFragmentContainingSlashIsDroppedWhole() {
        // 斜杠在 fragment 里时属于锚点的一部分，随 fragment 一起去掉。
        XCTAssertEqual(
            ShotStore.normalizedSourceURL("https://a.com#frag/"),
            "https://a.com"
        )
    }

    func testResultIsAlwaysPrefixOfInput() {
        // `relatedShots` 的前缀预筛依赖这个不变量。
        for raw in [
            "https://a.com/docs#intro",
            "https://a.com/docs/",
            "https://a.com/docs///#x",
            "https://a.com/docs",
            "https://a.com#frag/",
            ""
        ] {
            let normalized = ShotStore.normalizedSourceURL(raw)
            XCTAssertTrue(
                raw.hasPrefix(normalized),
                "归一化结果必须是原串前缀：\(normalized) vs \(raw)"
            )
        }
    }
}