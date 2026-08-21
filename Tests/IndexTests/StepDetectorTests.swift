import CoreGraphics
import XCTest
@testable import IndexApp

final class StepDetectorTests: XCTestCase {

    // MARK: - detectSteps（纯计算）
    //
    // 语义：步骤 0 = 初始状态（首次操作前）；步骤 i（i≥1）= 第 i 次操作 + 其后的
    // 静止期。代表帧落在该步尾部静止期中点 —— 抽到的是操作完成后的结果画面。

    /// 静止 → 操作 1 → 静止 → 操作 2 → 静止：初始状态 + 两次操作 = 3 步。
    func testInitialStatePlusTwoActions() {
        // 5fps：diffs[i] 是第 i 帧→第 i+1 帧。
        // 帧 0-4 静止，5-7 变化（操作 1），8-12 静止，13-15 变化（操作 2），16-20 静止。
        var diffs: [Double] = []
        for i in 0..<20 {
            let inAction = (i >= 5 && i < 8) || (i >= 13 && i < 16)
            diffs.append(inAction ? 0.2 : 0.0)
        }
        let steps = StepDetector.detectSteps(
            diffs: diffs,
            frameInterval: 0.2,
            videoDuration: 4.2
        )
        XCTAssertEqual(steps.count, 3)
        // 步骤 0：初始状态 [0, 1.0)，代表帧在初始静止期（帧 0-4）中点 0.5s。
        XCTAssertEqual(steps[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(steps[0].end, 1.0, accuracy: 0.01)
        XCTAssertEqual(steps[0].representativeTime, 0.5, accuracy: 0.11)
        // 步骤 1：操作 1 [1.0, 2.6)，代表帧在操作 1 的尾部静止期（帧 8-12）中点 2.1s。
        XCTAssertEqual(steps[1].start, 1.0, accuracy: 0.01)
        XCTAssertEqual(steps[1].end, 2.6, accuracy: 0.01)
        XCTAssertEqual(steps[1].representativeTime, 2.1, accuracy: 0.11)
        // 步骤 2：操作 2 [2.6, 4.2)，代表帧在操作 2 的尾部静止期（帧 16-20）中点 3.6s。
        XCTAssertEqual(steps[2].start, 2.6, accuracy: 0.01)
        XCTAssertEqual(steps[2].end, 4.2, accuracy: 0.01)
        XCTAssertEqual(steps[2].representativeTime, 3.6, accuracy: 0.11)
    }

    /// 全程静止：只有一个步骤（整段视频），代表帧在静止期中点。
    func testStaticVideoIsSingleStep() {
        let diffs = [Double](repeating: 0.0, count: 25)
        let steps = StepDetector.detectSteps(
            diffs: diffs,
            frameInterval: 0.2,
            videoDuration: 5.0
        )
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[0].end, 5.0)
        XCTAssertEqual(steps[0].representativeTime, 2.5, accuracy: 0.11)
    }

    /// 全程变化（无静止段）：只有一个步骤，代表帧取末尾。
    func testContinuousChangeIsSingleStep() {
        let diffs = [Double](repeating: 0.3, count: 25)
        let steps = StepDetector.detectSteps(
            diffs: diffs,
            frameInterval: 0.2,
            videoDuration: 5.0
        )
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[0].end, 5.0)
        XCTAssertEqual(steps[0].representativeTime, 4.95, accuracy: 0.01)
    }

    /// 两次操作之间静止不足 0.3s：不构成「完成态」，合并成一步。
    func testShortQuietBetweenActionsDoesNotSplit() {
        var diffs: [Double] = []
        for i in 0..<30 {
            // 操作 1：帧 5-7 变化；帧 8 静止（0.2s < 0.3s）；操作 2：帧 9-11 变化。
            let inAction = (i >= 5 && i < 8) || (i >= 9 && i < 12)
            diffs.append(inAction ? 0.2 : 0.0)
        }
        let steps = StepDetector.detectSteps(
            diffs: diffs,
            frameInterval: 0.2,
            videoDuration: 6.2
        )
        // 初始状态 + 合并后的双操作 = 2 步。
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(steps[0].end, 1.0, accuracy: 0.01)
        // 第二步代表帧在尾部静止期（帧 12-29）中点 4.2s。
        XCTAssertEqual(steps[1].start, 1.0, accuracy: 0.01)
        XCTAssertEqual(steps[1].end, 6.2, accuracy: 0.01)
        XCTAssertEqual(steps[1].representativeTime, 4.2, accuracy: 0.11)
    }

    /// 视频开头静止不足 0.5s：首个候选边界被防抖丢弃，初始短静止并入第一步。
    func testEarlyQuietDebouncedAgainstStart() {
        var diffs: [Double] = []
        for i in 0..<20 {
            // 帧 0-1 静止（0.4s < 0.5s 防抖），操作 1：帧 2-4，静止 5-9，
            // 操作 2：帧 10-12，静止 13-19。
            let inAction = (i >= 2 && i < 5) || (i >= 10 && i < 13)
            diffs.append(inAction ? 0.2 : 0.0)
        }
        let steps = StepDetector.detectSteps(
            diffs: diffs,
            frameInterval: 0.2,
            videoDuration: 4.0
        )
        // 若防抖失效，帧 2 处会多出一个 0.4s 边界 → 4 步；正确结果是 2 步。
        XCTAssertEqual(steps.count, 2)
        // 步骤 0：初始短静止 + 操作 1 [0, 2.0)，代表帧在操作 1 尾部静止期（帧 5-9）中点 1.5s。
        XCTAssertEqual(steps[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(steps[0].end, 2.0, accuracy: 0.01)
        XCTAssertEqual(steps[0].representativeTime, 1.5, accuracy: 0.11)
        // 步骤 1：操作 2 [2.0, 4.0)，代表帧在尾部静止期（帧 13-19）中点 3.3s。
        XCTAssertEqual(steps[1].start, 2.0, accuracy: 0.01)
        XCTAssertEqual(steps[1].end, 4.0, accuracy: 0.01)
        XCTAssertEqual(steps[1].representativeTime, 3.3, accuracy: 0.11)
    }

    /// 视频在变化中结束（最后一步无尾部静止段）：代表帧回退到步骤末尾。
    func testTrailingChangeFallsBackToStepEnd() {
        var diffs: [Double] = []
        for i in 0..<20 {
            // 操作 1：帧 5-7，静止 8-12，操作 2：帧 13-19（直到视频结束）。
            let inAction = (i >= 5 && i < 8) || i >= 13
            diffs.append(inAction ? 0.2 : 0.0)
        }
        let steps = StepDetector.detectSteps(
            diffs: diffs,
            frameInterval: 0.2,
            videoDuration: 4.0
        )
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[2].start, 2.6, accuracy: 0.01)
        XCTAssertEqual(steps[2].end, 4.0, accuracy: 0.01)
        XCTAssertEqual(steps[2].representativeTime, 3.95, accuracy: 0.01)
    }

    /// 空差异序列：至少一个步骤（整段视频）。
    func testEmptyDiffsStillYieldsOneStep() {
        let steps = StepDetector.detectSteps(
            diffs: [],
            frameInterval: 0.2,
            videoDuration: 1.0
        )
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[0].end, 1.0)
    }

    // MARK: - detectSteps(clicks:)（点击切分）

    /// 构造点击事件：默认位置 (100, 200)，便于断言 clickLocation 透传。
    private func click(_ time: Double, location: CGPoint = CGPoint(x: 100, y: 200)) -> ClickEvent {
        ClickEvent(time: time, location: location)
    }

    /// 两次点击 = 初始状态 + 两个操作步骤，代表帧取区间中点，位置透传。
    func testClicksProduceSteps() {
        let a = CGPoint(x: 120, y: 300)
        let b = CGPoint(x: 400, y: 80)
        let steps = StepDetector.detectSteps(
            clicks: [click(2.0, location: a), click(5.0, location: b)],
            videoDuration: 8.0
        )
        XCTAssertEqual(steps.count, 3)
        // 初始状态步骤无点击位置。
        XCTAssertNil(steps[0].clickLocation)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[0].end, 2.0)
        XCTAssertEqual(steps[0].representativeTime, 1.0)
        // 操作步骤携带触发点击的位置。
        XCTAssertEqual(steps[1].clickLocation, a)
        XCTAssertEqual(steps[1].start, 2.0)
        XCTAssertEqual(steps[1].end, 5.0)
        XCTAssertEqual(steps[1].representativeTime, 3.5)
        XCTAssertEqual(steps[2].clickLocation, b)
        XCTAssertEqual(steps[2].start, 5.0)
        XCTAssertEqual(steps[2].end, 8.0)
        XCTAssertEqual(steps[2].representativeTime, 6.5)
    }

    /// 首个点击距开头 ≥ 0.5s：开头单独成「初始状态」步骤。
    func testLateFirstClickKeepsInitialStateStep() {
        let steps = StepDetector.detectSteps(clicks: [click(3.0)], videoDuration: 6.0)
        XCTAssertEqual(steps.count, 2)
        XCTAssertNil(steps[0].clickLocation)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[0].end, 3.0)
        XCTAssertEqual(steps[0].representativeTime, 1.5)
        XCTAssertEqual(steps[1].start, 3.0)
        XCTAssertEqual(steps[1].end, 6.0)
    }

    /// 首个点击距开头 < 0.5s：不另设初始状态步骤（开头就是操作）。
    func testEarlyFirstClickMergesIntoFirstStep() {
        let steps = StepDetector.detectSteps(clicks: [click(0.3), click(4.0)], videoDuration: 6.0)
        XCTAssertEqual(steps.count, 2)
        XCTAssertNotNil(steps[0].clickLocation)
        XCTAssertEqual(steps[0].start, 0.3)
        XCTAssertEqual(steps[0].end, 4.0)
    }

    /// 双击（间隔 < 0.4s）合并成一个步骤起点，位置取第一个。
    func testDoubleClickIsMerged() {
        let first = CGPoint(x: 10, y: 20)
        let second = CGPoint(x: 999, y: 999)
        let steps = StepDetector.detectSteps(
            clicks: [click(2.0, location: first), click(2.2, location: second), click(5.0)],
            videoDuration: 8.0
        )
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[1].start, 2.0)
        XCTAssertEqual(steps[1].clickLocation, first, "双击合并应保留第一个点击的位置")
        XCTAssertEqual(steps[2].start, 5.0)
    }

    /// 乱序输入按时间排序后切分。
    func testUnorderedClicksAreSorted() {
        let steps = StepDetector.detectSteps(clicks: [click(5.0), click(2.0)], videoDuration: 8.0)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[1].start, 2.0)
        XCTAssertEqual(steps[2].start, 5.0)
    }

    /// 超出视频时长的点击被丢弃；全丢弃则返回空（调用方回退帧差）。
    func testClicksBeyondDurationAreDropped() {
        XCTAssertTrue(
            StepDetector.detectSteps(clicks: [click(9.0), click(10.0)], videoDuration: 8.0).isEmpty
        )
        let steps = StepDetector.detectSteps(clicks: [click(2.0), click(9.0)], videoDuration: 8.0)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].start, 0)
        XCTAssertEqual(steps[1].start, 2.0)
        XCTAssertEqual(steps[1].end, 8.0)
    }

    // MARK: - frameDiffs（CGImage 灰度差异）

    private func grayImage(_ value: UInt8, size: Int = 16) -> CGImage {
        let data = [UInt8](repeating: value, count: size * size)
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        data.withUnsafeBytes { buffer in
            context.data?.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count)
        }
        return context.makeImage()!
    }

    func testFrameDiffsDetectsChange() {
        let images = [grayImage(10), grayImage(10), grayImage(200)]
        let diffs = StepDetector.frameDiffs(images: images)
        XCTAssertEqual(diffs.count, 2)
        XCTAssertLessThan(diffs[0], StepDetector.quietThreshold, "相同帧差异应低于安静阈值")
        XCTAssertGreaterThan(diffs[1], StepDetector.quietThreshold, "大幅变化应高于安静阈值")
    }

    func testFrameDiffsEmptyForSingleImage() {
        XCTAssertTrue(StepDetector.frameDiffs(images: [grayImage(50)]).isEmpty)
    }
}
